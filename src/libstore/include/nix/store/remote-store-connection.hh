#pragma once
///@file

#include "nix/store/remote-store.hh"
#include "nix/store/worker-protocol.hh"
#include "nix/store/worker-protocol-connection.hh"
#include "nix/util/pool.hh"
#include "nix/util/lru-cache.hh"

namespace nix {

/**
 * Bidirectional connection (send and receive) used by the Remote Store
 * implementation.
 *
 * Contains `Source` and `Sink` for actual communication, along with
 * other information learned when negotiating the connection.
 */
struct RemoteStore::Connection : WorkerProto::BasicClientConnection, WorkerProto::ClientHandshakeInfo
{
private:
    /* VTable anchor to avoid weak linkage of the vtable - it breaks
       dynamic_cast across shared libraries on Darwin. */
    virtual void anchor();

public:
    /**
     * The streams that `to` and `from` refer to. Any buffered pair will
     * do: `FdSink`/`FdSource` for a connection driven by blocking I/O,
     * `AsyncFdSink`/`AsyncFdSource` for one driven from inside a
     * stackful coroutine (see `SSHStore`). They are passed in rather
     * than constructed here because the base class binds its references
     * before our members exist.
     */
    std::unique_ptr<BufferedSink> toOwned;
    std::unique_ptr<BufferedSource> fromOwned;

    Connection(std::unique_ptr<BufferedSink> to, std::unique_ptr<BufferedSource> from)
        : BasicClientConnection(*to, *from)
        , toOwned(std::move(to))
        , fromOwned(std::move(from))
    {
    }

    /**
     * The descriptor behind `from`, or `INVALID_DESCRIPTOR` when the
     * stream does not expose one. `shutdownConnections()` uses it to
     * break a blocking read from another thread, and `nix-daemon
     * --stdio` to forward the raw connection.
     */
    virtual Descriptor fromFd() const = 0;

    /**
     * The descriptor behind `to`; see `fromFd`.
     */
    virtual Descriptor toFd() const = 0;

    /**
     * Time this connection was established.
     */
    std::chrono::time_point<std::chrono::steady_clock> startTime;

    /**
     * Paths already pinned as temp roots on this connection.
     * Temp roots persist for the duration of the connection, so retransmission
     * is not required.
     * Skipping the wire call is an optional but worthwhile optimization that
     * reduces communication overhead. LRU eviction would cost a round-trip.
     */
    LRUCache<StorePath, bool> tempRootsPinned{65536};
};

/**
 * A wrapper around Pool<RemoteStore::Connection>::Handle that marks
 * the connection as bad (causing it to be closed) if a non-daemon
 * exception is thrown before the handle is closed. Such an exception
 * causes a deviation from the expected protocol and therefore a
 * desynchronization between the client and daemon.
 */
struct RemoteStore::ConnectionHandle
{
    Pool<RemoteStore::Connection>::Handle handle;
    bool daemonException = false;

    ConnectionHandle(Pool<RemoteStore::Connection>::Handle && handle)
        : handle(std::move(handle))
    {
    }

    ConnectionHandle(ConnectionHandle && h) noexcept
        : handle(std::move(h.handle))
    {
    }

    ~ConnectionHandle();

    RemoteStore::Connection & operator*()
    {
        return *handle;
    }

    RemoteStore::Connection * operator->()
    {
        return &*handle;
    }

    void processStderr(Sink * sink = 0, Source * source = 0, bool flush = true, bool block = true);

    void withFramedSink(fun<void(Sink & sink)> sendData);
};

} // namespace nix

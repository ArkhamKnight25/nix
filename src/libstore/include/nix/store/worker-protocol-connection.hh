#pragma once
///@file

#include "nix/store/worker-protocol.hh"
#include "nix/store/store-api.hh"

namespace nix {

struct WorkerProto::BasicConnection
{
    /**
     * Send with this.
     *
     * A reference rather than an `FdSink`, so that the same protocol
     * code can drive a connection through whatever buffered stream its
     * owner provides: a blocking `FdSink` in a thread, or an
     * `AsyncFdSink` inside a stackful coroutine, where a write that
     * would block suspends the coroutine instead of the thread. The
     * owner keeps the stream alive for as long as the connection.
     */
    BufferedSink & to;

    /**
     * Receive with this. See `to`.
     */
    BufferedSource & from;

    /**
     * The protocol version agreed by both sides.
     */
    WorkerProto::Version protoVersion;

    BasicConnection(BufferedSink & to, BufferedSource & from)
        : to(to)
        , from(from)
    {
    }

    /**
     * Coercion to `WorkerProto::ReadConn`. This makes it easy to use the
     * factored out serve protocol serializers with a
     * `LegacySSHStore::Connection`.
     *
     * The serve protocol connection types are unidirectional, unlike
     * this type.
     */
    operator WorkerProto::ReadConn()
    {
        return WorkerProto::ReadConn{
            .from = from,
            .version = protoVersion,
        };
    }

    /**
     * Coercion to `WorkerProto::WriteConn`. This makes it easy to use the
     * factored out serve protocol serializers with a
     * `LegacySSHStore::Connection`.
     *
     * The serve protocol connection types are unidirectional, unlike
     * this type.
     */
    operator WorkerProto::WriteConn()
    {
        return WorkerProto::WriteConn{
            .to = to,
            .version = protoVersion,
        };
    }
};

struct WorkerProto::BasicClientConnection : WorkerProto::BasicConnection
{
    using BasicConnection::BasicConnection;

    /**
     * Where the daemon's log messages, activities and results go when
     * `processStderr` reads them: the process's `logger`, looked up at
     * that moment (it may be replaced after this connection is made),
     * unless the connection's owner wants to see them pass, as the
     * in-process remote builder does to write the build's log file.
     */
    Logger * messageLogger = nullptr;

    /**
     * Flush to direction
     */
    virtual ~BasicClientConnection();

    virtual void closeWrite() = 0;

    std::exception_ptr processStderrReturn(Sink * sink = 0, Source * source = 0, bool flush = true, bool block = true);

    void
    processStderr(bool * daemonException, Sink * sink = 0, Source * source = 0, bool flush = true, bool block = true);

    /**
     * Establishes connection, negotiating version.
     *
     * @return The minimum version supported by both sides and the set
     * of protocol features supported by both sides.
     *
     * @param to Taken by reference to allow for various error handling
     * mechanisms.
     *
     * @param from Taken by reference to allow for various error
     * handling mechanisms.
     *
     * @param localVersion Our version (number + supported features)
     * which is sent over.
     */
    // FIXME: this should probably be a constructor.
    static Version handshake(BufferedSink & to, Source & from, const Version & localVersion);

    /**
     * After calling handshake, must call this to exchange some basic
     * information about the connection.
     */
    ClientHandshakeInfo postHandshake(const StoreDirConfig & store);

    void addTempRoot(const StoreDirConfig & remoteStore, bool * daemonException, const StorePath & path);

    StorePathSet queryValidPaths(
        const StoreDirConfig & remoteStore,
        bool * daemonException,
        const StorePathSet & paths,
        SubstituteFlag maybeSubstitute);

    std::optional<UnkeyedValidPathInfo>
    queryPathInfo(const StoreDirConfig & store, bool * daemonException, const StorePath & path);

    void putBuildDerivationRequest(
        const StoreDirConfig & store,
        bool * daemonException,
        const StorePath & drvPath,
        const BasicDerivation & drv,
        BuildMode buildMode);

    /**
     * Get the response, must be paired with
     * `putBuildDerivationRequest`.
     */
    BuildResult getBuildDerivationResponse(const StoreDirConfig & store, bool * daemonException);

    void narFromPath(
        const StoreDirConfig & store, bool * daemonException, const StorePath & path, fun<void(Source &)> receiveNar);
};

struct WorkerProto::BasicServerConnection : WorkerProto::BasicConnection
{
    /**
     * The descriptors the daemon serves on; `to` and `from` refer to
     * these. The base class binds its references before these members
     * are constructed, which is fine: it only takes their addresses.
     */
    FdSink toFd;
    FdSource fromFd;

    BasicServerConnection()
        : BasicConnection(toFd, fromFd)
    {
    }

    /**
     * Establishes connection, negotiating version.
     *
     * @return The version provided by the other side of the
     * connection.
     *
     * @param to Taken by reference to allow for various error handling
     * mechanisms.
     *
     * @param from Taken by reference to allow for various error
     * handling mechanisms.
     *
     * @param localVersion Our version (number + supported features)
     * which is sent over.
     */
    // FIXME: this should probably be a constructor.
    static Version handshake(BufferedSink & to, Source & from, const Version & localVersion);

    /**
     * After calling handshake, must call this to exchange some basic
     * information about the connection.
     */
    void postHandshake(const StoreDirConfig & store, const ClientHandshakeInfo & info);
};

} // namespace nix

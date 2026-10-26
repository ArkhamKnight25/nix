#pragma once

///@file

#include "nix/util/async.hh"
#include "nix/util/serialise.hh"
#include "nix/util/file-descriptor.hh"

#ifdef _WIN32
#  include <boost/asio/windows/stream_handle.hpp>
#else
#  include <boost/asio/posix/stream_descriptor.hpp>
#endif
#include <boost/asio/spawn.hpp>

#include <cassert>
#include <thread>

#ifndef _WIN32
#  include <cerrno>
#  include <poll.h>
#endif

namespace nix {

using NativeAsyncStreamDescriptor =
#ifndef _WIN32
    asio::posix::stream_descriptor
#else
    asio::windows::stream_handle
#endif
    ;

/**
 * @brief Source that reads from an owning Descriptor asynchronously.
 *
 * When the read would block, the caller is suspended. It's important to
 * ensure that this object is not migrated between coroutines.
 *
 * Nor between threads: `yield` suspends the coroutine running on the
 * thread that constructed this object, and a `Source` consumer that
 * reads from another thread (a `ThreadPool` behind `addMultipleToStore`,
 * say) would suspend a coroutine that thread is not running. Debug
 * builds assert on it.
 *
 * End of file is reported as `FdSource` reports it: `readUnbuffered`
 * throws `EndOfFile` carrying `endOfFileError`. `Source::operator()`
 * keeps reading until it has all the bytes it was asked for, so a
 * zero-length read would make it spin; `readLine` accepts either.
 */
class AsyncFdSource : public BufferedSource
{
    NativeAsyncStreamDescriptor fd;
    asio::yield_context yield;
    std::thread::id owner = std::this_thread::get_id();

public:
    /**
     * The message of the `EndOfFile` thrown when the descriptor is
     * exhausted; see `FdSource::endOfFileError`.
     */
    BackedStringView endOfFileError{"unexpected end-of-file"};

    AsyncFdSource(asio::io_context & ctx, asio::yield_context yield, AutoCloseFD fd)
        : fd(ctx, fd.release())
        , yield(std::move(yield))
    {
    }

    size_t readUnbuffered(char * data, size_t len) override
    {
        assert(std::this_thread::get_id() == owner);
        boost::system::error_code ec;
        auto res = fd.async_read_some(asio::mutable_buffer(data, len), yield[ec]);
        if (ec == boost::asio::error::eof || (!ec && res == 0))
            throw EndOfFile(std::string(*endOfFileError));
        else if (ec)
            throw SystemError(ec, "read of %1% bytes", len);
        return res;
    }

    /**
     * Whether a read would return at once: data in the buffer, or the
     * descriptor readable right now (data, EOF or error). The same
     * zero-timeout probe as `FdSource::hasData`, on the descriptor
     * asio holds, so that `processStderr(…, block = false)` drains the
     * daemon's messages between frames here as it does on a blocking
     * connection. The probe never suspends the coroutine.
     */
    bool hasData() override
    {
        if (BufferedSource::hasData())
            return true;
#ifdef _WIN32
        /* No readiness probe on an overlapped handle without issuing a
           read; the buffer is all we can tell. Nothing asynchronous
           runs on Windows yet. */
        return false;
#else
        while (true) {
            struct pollfd pfd;
            pfd.fd = fd.native_handle();
            pfd.events = POLLIN;
            pfd.revents = 0;

            auto n = ::poll(&pfd, 1, 0);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                throw SysError("polling file descriptor");
            }
            return n > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR)) != 0;
        }
#endif
    }
};

/**
 * @brief Sink that writes to an owning Descriptor asynchronously.
 *
 * When the write would block, the caller is suspended. It's important to
 * ensure that this object is not migrated between coroutines, nor used
 * from another thread; see `AsyncFdSource`.
 */
class AsyncFdSink : public BufferedSink
{
    NativeAsyncStreamDescriptor fd;
    asio::yield_context yield;
    std::thread::id owner = std::this_thread::get_id();

public:
    AsyncFdSink(asio::io_context & ctx, asio::yield_context yield, AutoCloseFD fd)
        : fd(ctx, fd.release())
        , yield(std::move(yield))
    {
    }

    /* Note that unlike ~FdSink we are intentionally not flushing on
       destruction, because potentially switching contexts during stack
       unwinding is very sketchy. */

    /**
     * Drop whatever is still buffered and close the descriptor, without
     * a context switch. For the writing half of a bidirectional
     * connection this is the half-close that tells the peer we are
     * done, and the caller has flushed first; in a destructor it is the
     * only safe way to let go of the descriptor, since flushing could
     * suspend during unwinding, and what is dropped was never going to
     * be sent. A failure to close is ignored for the same reason.
     */
    void close()
    {
        bufPos = 0;
        boost::system::error_code ec;
        if (fd.is_open())
            fd.close(ec);
    }

    void writeUnbuffered(std::string_view data) override
    {
        assert(std::this_thread::get_id() == owner);
        while (!data.empty()) {
            boost::system::error_code ec;
            auto consumed = fd.async_write_some(asio::buffer(data.data(), data.size()), yield[ec]);
            if (ec)
                throw SystemError(ec, "write of %1% bytes", data.size());
            data.remove_prefix(consumed);
        }
    }
};

} // namespace nix

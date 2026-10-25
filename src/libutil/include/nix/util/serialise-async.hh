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
 * Nor between threads: `yield` belongs to a coroutine on the constructing
 * thread, so a read from a `ThreadPool` would suspend the wrong one. This
 * is asserted, and Nix does not build with `NDEBUG`.
 *
 * End of file throws `EndOfFile` with `endOfFileError`, as in `FdSource`.
 * Returning 0 would make `Source::operator()` spin.
 */
class AsyncFdSource : public BufferedSource
{
    NativeAsyncStreamDescriptor fd;
    asio::yield_context yield;
    std::thread::id owner = std::this_thread::get_id();
    bool _good = true;

public:
    /**
     * The message of the `EndOfFile` thrown at end of file.
     */
    BackedStringView endOfFileError{"unexpected end-of-file"};

    AsyncFdSource(asio::io_context & ctx, asio::yield_context yield, AutoCloseFD fd)
        : fd(ctx, fd.release())
        , yield(std::move(yield))
    {
    }

    ~AsyncFdSource();

    size_t readUnbuffered(char * data, size_t len) override
    {
        assert(std::this_thread::get_id() == owner);
        boost::system::error_code ec;
        std::size_t res;
        try {
            res = fd.async_read_some(asio::mutable_buffer(data, len), yield[ec]);
        } catch (boost::system::system_error & e) {
            /* With `throw_if_cancelled` set, an operation started after a
               cancellation throws here instead of setting `ec`. */
            _good = false;
            throw SystemError(e.code(), "read of %1% bytes", len);
        }
        if (ec == boost::asio::error::eof || (!ec && res == 0)) {
            _good = false;
            throw EndOfFile(std::string(*endOfFileError));
        } else if (ec) {
            _good = false;
            throw SystemError(ec, "read of %1% bytes", len);
        }
        return res;
    }

    /**
     * False after end of file or an error, as for `FdSource`, so that a
     * connection pool drops this connection instead of reusing it.
     */
    bool good() override
    {
        return _good;
    }

    /**
     * Whether a read would return at once, without suspending. Polls the
     * descriptor like `FdSource::hasData`, so that non-blocking
     * `processStderr` drains the daemon's messages here too.
     */
    bool hasData() override
    {
        if (BufferedSource::hasData())
            return true;
#ifdef _WIN32
        /* An overlapped handle cannot be probed without issuing a read.
           Nothing asynchronous runs on Windows yet. */
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
    bool _good = true;

public:
    AsyncFdSink(asio::io_context & ctx, asio::yield_context yield, AutoCloseFD fd)
        : fd(ctx, fd.release())
        , yield(std::move(yield))
    {
    }

    /* Note that unlike ~FdSink we are intentionally not flushing on
       destruction, because potentially switching contexts during stack
       unwinding is very sketchy. */
    ~AsyncFdSink();

    /**
     * Drop anything still buffered and close the descriptor without a
     * context switch, so that it is safe in a destructor. To half-close a
     * connection, flush first. Errors from closing are ignored.
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
            std::size_t consumed;
            try {
                consumed = fd.async_write_some(asio::buffer(data.data(), data.size()), yield[ec]);
            } catch (boost::system::system_error & e) {
                _good = false;
                throw SystemError(e.code(), "write of %1% bytes", data.size());
            }
            if (ec) {
                _good = false;
                throw SystemError(ec, "write of %1% bytes", data.size());
            }
            data.remove_prefix(consumed);
        }
    }

    /**
     * False after a failed write, as for `FdSink`.
     */
    bool good() override
    {
        return _good;
    }
};

} // namespace nix

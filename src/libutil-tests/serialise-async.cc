#include "nix/util/serialise-async.hh"
#include "nix/util/archive.hh"
#include "nix/util/memory-source-accessor.hh"
#include "nix/util/tests/gmock-matchers.hh"

#include <boost/asio/bind_cancellation_slot.hpp>
#include <boost/asio/cancellation_signal.hpp>
#include <boost/asio/error.hpp>
#include <boost/asio/post.hpp>
#include <boost/asio/use_future.hpp>

#include <gtest/gtest.h>

namespace nix {

class AsyncFdTest : public ::testing::Test
{
protected:
    asio::io_context ctx;
};

/* Note that in practice we'd want to run with the protected_fixedsize_stack allocator. */

TEST_F(AsyncFdTest, dumpStringThroughPipe)
{
    Pipe pipe;
    pipe.create();

    std::string contents(1000000, 'x');

    auto write = asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            AsyncFdSink sink(ctx, yield, std::move(pipe.writeSide));
            dumpString(contents, sink);
            sink.flush();
        },
        asio::use_future);

    auto read = asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            AsyncFdSource source(ctx, yield, std::move(pipe.readSide));
            std::unique_ptr<MemorySourceAccessor> accessor = std::make_unique<MemorySourceAccessor>();
            MemorySink fsSink(*accessor);
            parseDump(fsSink, source);
            return accessor;
        },
        asio::use_future);

    ctx.run();

    std::unique_ptr<MemorySourceAccessor> accessor;

    ASSERT_NO_THROW(accessor = read.get());
    ASSERT_NO_THROW(write.get());
    EXPECT_THAT(accessor, ::nix::testing::HasContents(CanonPath::root, contents));
}

TEST_F(AsyncFdTest, writeToInvalidFd)
{
    Pipe pipe;
    pipe.create();

    auto write = asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            Descriptor fd = pipe.writeSide.get();
            AsyncFdSink sink(ctx, yield, std::move(pipe.writeSide));
            ::close(fd);
            sink << "hello";
            sink.flush();
        },
        asio::use_future);

    ctx.run();
    EXPECT_THROW(write.get(), SystemError);
}

/* The two tests below are skeletons: written against the headers, not
   yet run. */

TEST_F(AsyncFdTest, eofThrowsEndOfFile)
{
    Pipe pipe;
    pipe.create();
    pipe.writeSide.close();

    auto read = asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            AsyncFdSource source(ctx, yield, std::move(pipe.readSide));
            source.endOfFileError = "the other side went away";
            char c;
            /* `Source::operator()` would spin on a zero-length read. */
            source(&c, 1);
        },
        asio::use_future);

    ctx.run();
    EXPECT_THROW(read.get(), EndOfFile);
}

TEST_F(AsyncFdTest, hasDataProbesTheDescriptorThroughTheBase)
{
    Pipe pipe;
    pipe.create();

    auto probe = asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            AsyncFdSource source(ctx, yield, std::move(pipe.readSide));
            /* As `processStderr` sees it. */
            BufferedSource & base = source;
            bool before = base.hasData();
            writeFull(pipe.writeSide.get(), "x");
            bool after = base.hasData();
            return std::pair{before, after};
        },
        asio::use_future);

    ctx.run();
    auto [before, after] = probe.get();
    EXPECT_FALSE(before);
    EXPECT_TRUE(after);
}

/* Skeleton, written against the headers and not yet run. The shape
   `DerivationBuildingGoal::buildRemotely` relies on when its goal is
   destroyed: a coroutine suspended on a read, a `cancellation_signal`
   bound to its completion, and the signal emitted from the loop. The
   pending read must complete with `operation_aborted`, the coroutine
   unwind with that error, and the loop run dry afterwards; a read that
   ignored the cancellation would leave `~Worker` waiting. */
TEST_F(AsyncFdTest, terminalCancellationAbortsASuspendedRead)
{
    Pipe pipe;
    pipe.create();

    asio::cancellation_signal cancel;
    std::exception_ptr error;
    bool completed = false;

    asio::spawn(
        ctx,
        [&](asio::yield_context yield) {
            AsyncFdSource source(ctx, yield, std::move(pipe.readSide));
            char c;
            /* Nobody writes, so this suspends until cancelled. */
            source(&c, 1);
        },
        asio::bind_cancellation_slot(cancel.slot(), [&](std::exception_ptr e) {
            completed = true;
            error = e;
        }));

    /* Run the coroutine up to its suspension on the read. */
    ctx.poll();
    ASSERT_FALSE(completed);

    /* From the loop, as `onLogLimitExceeded` and `CancelOnExit` do. */
    asio::post(ctx, [&]() { cancel.emit(asio::cancellation_type::terminal); });
    ctx.run();

    ASSERT_TRUE(completed);
    ASSERT_TRUE(error);
    try {
        std::rethrow_exception(error);
    } catch (SystemError & e) {
        EXPECT_EQ(e.ec(), std::error_code(asio::error::make_error_code(asio::error::operation_aborted)));
    } catch (...) {
        FAIL() << "expected a SystemError carrying operation_aborted";
    }
    /* Nothing left on the loop: the cancelled read was its only work. */
    EXPECT_TRUE(ctx.stopped());
}

} // namespace nix

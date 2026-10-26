#include "nix/util/serialise-async.hh"
#include "nix/util/archive.hh"
#include "nix/util/memory-source-accessor.hh"
#include "nix/util/tests/gmock-matchers.hh"

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

} // namespace nix

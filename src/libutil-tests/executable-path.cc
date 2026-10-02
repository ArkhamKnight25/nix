#include <gtest/gtest.h>

#include "nix/util/executable-path.hh"

namespace nix {

#ifdef WIN32
#  define PATH_VAR_SEP L";"
#else
#  define PATH_VAR_SEP ":"
#endif

#define PATH_ENV_ROUND_TRIP(NAME, STRING_LIT, CXX_LIT) \
    TEST(ExecutablePath, NAME)                         \
    {                                                  \
        OsString s = STRING_LIT;                       \
        auto v = ExecutablePath::parse(s);             \
        EXPECT_EQ(v, (ExecutablePath CXX_LIT));        \
        auto s2 = v.render();                          \
        EXPECT_EQ(s2, s);                              \
    }

PATH_ENV_ROUND_TRIP(emptyRoundTrip, OS_STR(""), ({}))

PATH_ENV_ROUND_TRIP(
    oneElemRoundTrip,
    OS_STR("/foo"),
    ({
        OS_STR("/foo"),
    }))

PATH_ENV_ROUND_TRIP(
    twoElemsRoundTrip,
    OS_STR("/foo" PATH_VAR_SEP "/bar"),
    ({
        OS_STR("/foo"),
        OS_STR("/bar"),
    }))

PATH_ENV_ROUND_TRIP(
    threeElemsRoundTrip,
    OS_STR("/foo" PATH_VAR_SEP "." PATH_VAR_SEP "/bar"),
    ({
        OS_STR("/foo"),
        OS_STR("."),
        OS_STR("/bar"),
    }))

TEST(ExecutablePath, elementyElemNormalize)
{
    auto v = ExecutablePath::parse(PATH_VAR_SEP PATH_VAR_SEP PATH_VAR_SEP);
    EXPECT_EQ(
        v,
        (ExecutablePath{{
            OS_STR("."),
            OS_STR("."),
            OS_STR("."),
            OS_STR("."),
        }}));
    auto s2 = v.render();
    EXPECT_EQ(s2, OS_STR("." PATH_VAR_SEP "." PATH_VAR_SEP "." PATH_VAR_SEP "."));
}

TEST(ExecutablePath, findPathAbsolute)
{
    ExecutablePath p{{OS_STR("/dir")}};
    // A pathname containing a slash is not searched for in the path,
    // and is returned whether or not anything deems it executable.
    auto path = p.findPath(std::filesystem::path("/foo/bar"), [](auto &) { return false; });
    EXPECT_EQ(path, std::filesystem::path("/foo/bar"));
}

TEST(ExecutablePath, findPathRelativeWithSlash)
{
    ExecutablePath p{{OS_STR("/dir")}};
    auto path = p.findPath(std::filesystem::path("foo/bar"), [](auto &) { return false; });
    EXPECT_EQ(path, std::filesystem::path("foo/bar"));
}

TEST(ExecutablePath, findPathSearches)
{
    ExecutablePath p{{OS_STR("/no"), OS_STR("/yes")}};
    auto path = p.findPath(std::filesystem::path("exe"), [](const std::filesystem::path & candidate) {
        return candidate.string().find("yes") != std::string::npos;
    });
    EXPECT_EQ(path, (std::filesystem::path("/yes") / "exe").lexically_normal());
}

TEST(ExecutablePath, findPathNotFoundThrows)
{
    ExecutablePath p{{OS_STR("/dir")}};
    EXPECT_THROW(p.findPath(std::filesystem::path("exe"), [](auto &) { return false; }), ExecutableLookupError);
}

} // namespace nix

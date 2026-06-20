#include <gtest/gtest.h>

#include "nix/store/build.hh"
#include "nix/store/build-result.hh"
#include "nix/store/derivations.hh"

namespace nix {

/* A mock Builder recording which overload was called and with what inputs. */
struct MockBuilder : Builder
{
    enum class Call {
        None,
        BuildDerivation,
        BuildDerivationWithInputs,
        BuildPaths,
        BuildPathsWithResults,
        BuildPathsWithResultsWithInputs,
    };

    Call lastCall = Call::None;
    StorePathSet lastInputs;

    void buildPaths(const std::vector<DerivedPath> &, BuildMode) override
    {
        lastCall = Call::BuildPaths;
    }

    std::vector<KeyedBuildResult> buildPathsWithResults(const std::vector<DerivedPath> &, BuildMode) override
    {
        lastCall = Call::BuildPathsWithResults;
        return {};
    }

    BuildResult buildDerivation(const StorePath &, const BasicDerivation &, BuildMode) override
    {
        lastCall = Call::BuildDerivation;
        return BuildResult{};
    }

    BuildResult
    buildDerivation(const StorePath &, const BasicDerivation &, const StorePathSet & inputs, BuildMode) override
    {
        lastCall = Call::BuildDerivationWithInputs;
        lastInputs = inputs;
        return BuildResult{};
    }

    std::vector<KeyedBuildResult>
    buildPathsWithResults(const std::vector<DerivedPath> &, const StorePathSet & inputs, BuildMode) override
    {
        lastCall = Call::BuildPathsWithResultsWithInputs;
        lastInputs = inputs;
        return {};
    }

    void ensurePath(const StorePath &) override {}
    void repairPath(const StorePath &) override {}
};

/* Mirror of the trust-split in build-remote.cc:326/:352. */
static void dispatchForTrust(
    MockBuilder & b,
    bool trustedOrLegacy,
    bool isCA,
    const StorePath & drvPath,
    const BasicDerivation & drv,
    const StorePathSet & inputs)
{
    if (trustedOrLegacy || isCA) {
        b.buildDerivation(drvPath, drv, inputs, bmNormal);
    } else {
        b.buildPathsWithResults(
            {DerivedPath::Built{
                .drvPath = makeConstantStorePathRef(drvPath),
                .outputs = OutputsSpec::All{},
            }},
            inputs,
            bmNormal);
    }
}

class BuilderInputs : public ::testing::Test
{
protected:
    StorePath drvPath = StorePath::dummy;
    BasicDerivation drv{};
    StorePathSet inputs{StorePath::dummy};
};

TEST_F(BuilderInputs, trustedPicksBuildDerivation)
{
    MockBuilder b;
    dispatchForTrust(b, /*trusted*/ true, /*ca*/ false, drvPath, drv, inputs);
    EXPECT_EQ(b.lastCall, MockBuilder::Call::BuildDerivationWithInputs);
}

TEST_F(BuilderInputs, caPicksBuildDerivationEvenWhenUntrusted)
{
    MockBuilder b;
    dispatchForTrust(b, /*trusted*/ false, /*ca*/ true, drvPath, drv, inputs);
    EXPECT_EQ(b.lastCall, MockBuilder::Call::BuildDerivationWithInputs);
}

TEST_F(BuilderInputs, untrustedNonCAPicksBuildPathsWithResults)
{
    MockBuilder b;
    dispatchForTrust(b, /*trusted*/ false, /*ca*/ false, drvPath, drv, inputs);
    EXPECT_EQ(b.lastCall, MockBuilder::Call::BuildPathsWithResultsWithInputs);
}

TEST_F(BuilderInputs, inputsForwardedIntact)
{
    MockBuilder b;
    dispatchForTrust(b, /*trusted*/ true, /*ca*/ false, drvPath, drv, inputs);
    EXPECT_EQ(b.lastInputs, inputs);
}

TEST_F(BuilderInputs, emptyInputSetIsForwarded)
{
    MockBuilder b;
    StorePathSet empty;
    dispatchForTrust(b, /*trusted*/ true, /*ca*/ false, drvPath, drv, empty);
    EXPECT_EQ(b.lastCall, MockBuilder::Call::BuildDerivationWithInputs);
    EXPECT_TRUE(b.lastInputs.empty());
}

} // namespace nix

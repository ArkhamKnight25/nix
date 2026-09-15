#include "nix/store/machine-selection.hh"

#include <gtest/gtest.h>

namespace nix {

static Machine testMachine(
    const std::string & storeUri,
    float speedFactor = 1.0f,
    StringSet supportedFeatures = {},
    StringSet mandatoryFeatures = {})
{
    return Machine(
        storeUri,
        {"TEST_ARCH-TEST_OS"},
        std::nullopt,
        /*maxJobs=*/1,
        speedFactor,
        std::move(supportedFeatures),
        std::move(mandatoryFeatures),
        /*sshPublicHostKey=*/"");
}

TEST(machineSelection, candidateAcceptsMatchingSystem)
{
    auto m = testMachine("ssh://localhost");
    EXPECT_TRUE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {}));
}

TEST(machineSelection, candidateAcceptsBuiltin)
{
    auto m = testMachine("ssh://localhost");
    EXPECT_TRUE(machineIsCandidate(m, "builtin", {}));
}

TEST(machineSelection, candidateRejectsOtherSystem)
{
    auto m = testMachine("ssh://localhost");
    EXPECT_FALSE(machineIsCandidate(m, "OTHER_ARCH-OTHER_OS", {}));
}

TEST(machineSelection, candidateRejectsDisabled)
{
    auto m = testMachine("ssh://localhost");
    m.enabled = false;
    EXPECT_FALSE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {}));
}

TEST(machineSelection, candidateRejectsUnsupportedFeature)
{
    auto m = testMachine("ssh://localhost");
    EXPECT_FALSE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {"big-parallel"}));
}

TEST(machineSelection, candidateAcceptsSupportedFeature)
{
    auto m = testMachine("ssh://localhost", 1.0f, {"big-parallel"});
    EXPECT_TRUE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {"big-parallel"}));
}

TEST(machineSelection, candidateRejectsUnrequestedMandatoryFeature)
{
    auto m = testMachine("ssh://localhost", 1.0f, {}, {"benchmark"});
    EXPECT_FALSE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {}));
    EXPECT_TRUE(machineIsCandidate(m, "TEST_ARCH-TEST_OS", {"benchmark"}));
}

TEST(machineSelection, betterPrefersTheLessLoadedOfTwoEqualMachines)
{
    auto cand = testMachine("ssh://a");
    auto best = testMachine("ssh://b");
    EXPECT_TRUE(machineIsBetter(cand, 0, best, 1));
    EXPECT_FALSE(machineIsBetter(cand, 1, best, 0));
}

TEST(machineSelection, betterKeepsTheIncumbentOnAnExactTie)
{
    auto cand = testMachine("ssh://a");
    auto best = testMachine("ssh://b");
    EXPECT_FALSE(machineIsBetter(cand, 1, best, 1));
}

TEST(machineSelection, betterWeighsLoadBySpeedFactor)
{
    auto fast = testMachine("ssh://fast", 10.0f);
    auto slow = testMachine("ssh://slow", 1.0f);
    /* The fast machine is running five builds and the slow one none, but
       5/10 is still worse than 0/1. */
    EXPECT_TRUE(machineIsBetter(slow, 0, fast, 5));
    /* One build on the fast machine (0.1) beats none on the slow one (0). */
    EXPECT_FALSE(machineIsBetter(slow, 1, fast, 1));
}

TEST(machineSelection, betterBreaksWeightedTiesBySpeedFactor)
{
    auto fast = testMachine("ssh://fast", 2.0f);
    auto slow = testMachine("ssh://slow", 1.0f);
    /* 2/2 == 1/1, so the faster machine wins. */
    EXPECT_TRUE(machineIsBetter(fast, 2, slow, 1));
    EXPECT_FALSE(machineIsBetter(slow, 1, fast, 2));
}

TEST(machineSelection, betterBreaksSpeedTiesByAbsoluteLoad)
{
    auto a = testMachine("ssh://a", 1.0f);
    auto b = testMachine("ssh://b", 1.0f);
    EXPECT_TRUE(machineIsBetter(a, 2, b, 3));
    EXPECT_FALSE(machineIsBetter(a, 3, b, 2));
}

TEST(machineSelection, escapeUriMakesAStoreUriAPathComponent)
{
    EXPECT_EQ(escapeUri("ssh://user@host"), "ssh:__user@host");
    EXPECT_EQ(escapeUri("/var/lib/nix"), "_var_lib_nix");
}

} // namespace nix

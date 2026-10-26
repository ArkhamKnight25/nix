#pragma once
///@file

#include "nix/store/derivations.hh"
#include "nix/store/local-store.hh"
#include "nix/store/parsed-derivations.hh"
#include "nix/store/derivation-options.hh"
#include "nix/store/build/derivation-building-misc.hh"
#include "nix/store/store-api.hh"
#include "nix/store/pathlocks.hh"
#include "nix/store/build/goal.hh"
#include "nix/store/build/build-log.hh"
#include "nix/store/machine-selection.hh"

namespace nix {

using std::map;

struct BuilderFailureError;
struct ExternalBuilder;
#ifndef _WIN32 // TODO enable build hook on Windows
struct HookInstance;
struct DerivationBuilder;
#endif

typedef enum { rpAccept, rpDecline, rpPostpone } HookReply;

/**
 * A goal for building a derivation. Substitution, (or any other method of
 * obtaining the outputs) will not be attempted, so it is the calling goal's
 * responsibility to try to substitute first.
 */
struct DerivationBuildingGoal : public Goal
{
    friend class Worker;

    /**
     * @param drv The derivation to build, with the outputs of its input
     * derivations already added to its input sources.
     */
    DerivationBuildingGoal(
        const StorePath & drvPath, ref<const BasicDerivation> drv, Worker & worker, BuildMode buildMode);
    ~DerivationBuildingGoal();

private:

    /** The path of the derivation. */
    const StorePath drvPath;

    /**
     * The derivation to build.
     */
    const ref<const BasicDerivation> drv;

    /**
     * The remainder is state held during the build.
     */

    const BuildMode buildMode;

    std::unique_ptr<MaintainCount<uint64_t>> mcRunningBuilds;

    std::string key() override;

    struct LocalBuildCapability
    {
        LocalStore & localStore;
        const ExternalBuilder * externalBuilder;
    };

    /**
     * The states.
     */
    using Result = decltype(BuildResult::inner);

    struct NeedsSlot
    {};

    using LocalBuildOutcome = std::variant<Result, NeedsSlot>;

    Co<ExitCode> init();
    Co<void> realiseInputs();
    Co<Result> tryToBuild();
    Co<Result> buildWithHook(
        const StorePathSet & inputPaths, std::map<std::string, InitialOutput> & initialOutputs, PathLocks outputLocks);
    Co<LocalBuildOutcome> buildLocally(
        LocalBuildCapability localBuildCap,
        const StorePathSet & inputPaths,
        std::map<std::string, InitialOutput> & initialOutputs,
        const DerivationOptions<StorePath> & drvOptions,
        PathLocks outputLocks);

    /**
     * Is the build hook willing to perform the build? On `rpAccept`, the
     * hook and the machine it named are left in `hookAccepted` and
     * `hookMachineName` for `buildWithHook`.
     */
    Co<HookReply> tryBuildHook(const DerivationOptions<StorePath> & drvOptions);

#ifndef _WIN32
    /** The accepting hook and its machine, for `buildWithHook`. */
    std::unique_ptr<HookInstance> hookAccepted;
    std::string hookMachineName;
#endif

    /**
     * A reply to a remote build request. `machine` holds the slot the
     * worker reserved, and is empty when the hook program answered.
     */
    struct RemoteReply
    {
        HookReply reply = rpDecline;
        std::optional<AcquiredMachine> machine;
    };

    /**
     * Ask for a remote build: of the hook program when `build-hook` is
     * set, otherwise of the worker's own remote builder.
     */
    Co<RemoteReply> tryRemoteBuilder(const DerivationOptions<StorePath> & drvOptions);

#ifndef _WIN32
    /**
     * Reserve a slot on the least loaded machine that can run this build,
     * replying as the hook would. Takes lock files only, so it need not
     * be a coroutine.
     */
    RemoteReply selectRemoteMachine(const DerivationOptions<StorePath> & drvOptions);

    /**
     * Build on the machine `selectRemoteMachine` reserved, in a stackful
     * coroutine on `worker.ioContext` so that other goals keep running.
     * Returns `std::nullopt` when no machine could be reached after all;
     * the caller then asks `tryRemoteBuilder` again.
     */
    Co<std::optional<Result>> buildRemotely(
        AcquiredMachine machine,
        const DerivationOptions<StorePath> & drvOptions,
        const StorePathSet & inputPaths,
        std::map<std::string, InitialOutput> & initialOutputs,
        PathLocks outputLocks);
#endif

    BuildError logLimitExceeded();

    /**
     * Wrappers around the corresponding Store methods that first consult the
     * derivation.  This is currently needed because when there is no drv file
     * there also is no DB entry.
     */
    std::map<std::string, std::optional<StorePath>> queryPartialDerivationOutputMap();

    /**
     * Update 'initialOutputs' to determine the current status of the
     * outputs of the derivation. Also returns a Boolean denoting
     * whether all outputs are valid and non-corrupt, and a
     * 'SingleDrvOutputs' structure containing the valid outputs.
     */
    std::pair<bool, SingleDrvOutputs> checkPathValidity(std::map<std::string, InitialOutput> & initialOutputs);

    BuildError fixupBuilderFailureErrorMessage(BuilderFailureError msg, BuildLog & buildLog);

    JobCategory jobCategory() const override
    {
        return JobCategory::Build;
    };
};

} // namespace nix

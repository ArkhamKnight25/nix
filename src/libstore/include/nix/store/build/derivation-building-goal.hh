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
     * Is the build hook willing to perform the build?
     */
    HookReply tryBuildHook(const DerivationOptions<StorePath> & drvOptions);

    /**
     * The answer to a request for a remote build, from whichever side
     * handles it: the configured hook program (`machine` empty; the
     * accepting hook is `worker.hook`) or the worker itself (`machine`
     * holds the slot it reserved).
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
    RemoteReply tryRemoteBuilder(const DerivationOptions<StorePath> & drvOptions);

#ifndef _WIN32
    /**
     * The worker's own answer, with no hook process: reserve a slot on
     * the least loaded machine that can run this build. Lock files
     * only, so this is synchronous. `rpPostpone` when every fitting
     * machine is full and we cannot build locally either, `rpDecline`
     * when none fits.
     */
    RemoteReply selectRemoteMachine(const DerivationOptions<StorePath> & drvOptions);

    /**
     * Build on the machine `selectRemoteMachine` reserved. The
     * connection, the copies and the build run as a stackful coroutine
     * on `worker.ioContext` (see `buildOnRemoteMachine`), so the worker
     * keeps running other goals meanwhile; this goal sleeps until the
     * coroutine is done. Returns `std::nullopt` when no machine could be
     * reached after all, in which case the caller builds locally, as it
     * would after a hook's `decline`.
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

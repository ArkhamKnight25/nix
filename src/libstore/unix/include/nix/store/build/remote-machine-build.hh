#pragma once
///@file

#include "nix/store/build-result.hh"
#include "nix/store/derivations.hh"
#include "nix/store/machine-selection.hh"
#include "nix/store/machines.hh"
#include "nix/store/store-api.hh"
#include "nix/util/serialise-async.hh"

#include <functional>
#include <variant>

namespace nix {

/**
 * What the build hook protocol's `try` request and the message after an
 * `accept` carry, for `buildOnRemoteMachine`.
 */
struct RemoteMachineBuildRequest
{
    StorePath drvPath;

    /**
     * With the outputs of its input derivations already among its
     * input sources.
     */
    ref<const BasicDerivation> drv;

    std::string neededSystem;
    StringSet requiredFeatures;

    /**
     * The input closure to copy to the machine first.
     */
    StorePathSet inputPaths;

    /**
     * The outputs to copy back.
     */
    StringSet wantedOutputs;

    /**
     * Where the machine's messages go, if not to `logger`. Shared, so
     * that it outlives the coroutine however that ends.
     */
    std::shared_ptr<Logger> messageLogger;

    /**
     * Called with the store URI of the machine connected to, which after
     * a failover is not the one first selected.
     */
    std::function<void(const std::string &)> onMachine;

    /**
     * The machines this build has found unreachable, to skip and add to.
     * If null, the attempt uses a set of its own.
     */
    std::shared_ptr<std::set<const Machine *>> unreachable;
};

/**
 * No machine ran the build: the reserved one could not be reached, and no
 * other fits or is free. `AllBusy` also means the next one in line is for
 * the hook process; the goal asks `tryRemoteBuilder` again, which can tell.
 */
struct RemoteMachineUnavailable
{
    NoMachine why;
};

struct RemoteMachineBuilt
{
    /**
     * The machine's store URI, for messages.
     */
    std::string storeUri;

    /**
     * The machine's verdict. On success the outputs have been copied
     * into the local store.
     */
    BuildResult result;
};

using RemoteMachineBuildOutcome = std::variant<RemoteMachineBuilt, RemoteMachineUnavailable>;

/**
 * Whether builds for this machine run in the worker (`ssh-ng`). Any other
 * goes to the hook process, so that it does not block the worker.
 */
bool machineRunsInProcess(const Machine & machine);

/**
 * Build `req.drv` on `acquired.machine`, or on another of `machines` if
 * that one cannot be reached, suspending the coroutine `yield` on `ctx`
 * at every read and write. Keeps the slot of `acquired` until it returns.
 * When cancelled, throws with `operation_aborted`.
 */
RemoteMachineBuildOutcome buildOnRemoteMachine(
    Store & store,
    Machines & machines,
    AcquiredMachine acquired,
    const RemoteMachineBuildRequest & req,
    asio::io_context & ctx,
    asio::yield_context yield);

} // namespace nix

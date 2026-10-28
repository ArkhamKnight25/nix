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
 * What `buildOnRemoteMachine` is asked to do: the fields of the build
 * hook protocol's `try` request and of the message that follows an
 * `accept`, in one place.
 */
struct RemoteMachineBuildRequest
{
    StorePath drvPath;

    /**
     * With the outputs of its input derivations already among its
     * input sources, as `DerivationBuildingGoal` holds it.
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
     * Where the machine's messages go, if not to the process's
     * `logger`; see `BasicClientConnection::messageLogger`. Shared, so
     * that it outlives the coroutine however that ends.
     */
    std::shared_ptr<Logger> messageLogger;

    /**
     * Where a machine's build output goes when it arrives as bytes
     * rather than as log messages: a legacy `ssh://` machine's build log
     * is ssh's stderr. Called from a thread of its own, since the store
     * producing it blocks the worker's thread; see `openMachineStore`.
     * Empty: the output is not collected.
     */
    std::function<void(std::string_view)> rawBuildOutput;
};

/**
 * No machine took the build after all: the one reserved could not be
 * reached, nor any other. `AllBusy` is what the hook replied `postpone`
 * to, `WrongType` what it replied `decline` to.
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
 * Whether builds for this machine run in the worker (`ssh-ng`, spoken to
 * asynchronously). Any other machine goes to the hook process, so that it
 * does not hold up the worker.
 */
bool machineRunsInProcess(const Machine & machine);

/**
 * Build `req.drv` on `acquired.machine`, or on another machine from
 * `machines` if that one cannot be reached: connect, copy the inputs
 * over, build, copy the outputs back into `store`. This is what
 * `serveBuildHook` does once it has accepted a build, as a function
 * that runs inside a stackful coroutine: `yield` is that coroutine's,
 * `ctx` the loop it is suspended on. Every read from or write to the
 * machine suspends the coroutine; only the local store's own work
 * (reading the inputs, writing the outputs) occupies the thread.
 *
 * The slot reserved by `acquired` stays reserved until this returns; it
 * is what other builds count as the machine's load. A machine that
 * cannot be reached is disabled in `machines`.
 *
 * Throws on anything that is neither a build failure (reported in the
 * result) nor the lack of a machine. A cancelled coroutine throws with
 * `operation_aborted`: a `SystemError` from an operation that was pending
 * when the cancellation came, or a `boost::system::system_error` from one
 * started after it.
 */
RemoteMachineBuildOutcome buildOnRemoteMachine(
    Store & store,
    Machines & machines,
    AcquiredMachine acquired,
    const RemoteMachineBuildRequest & req,
    asio::io_context & ctx,
    asio::yield_context yield);

} // namespace nix

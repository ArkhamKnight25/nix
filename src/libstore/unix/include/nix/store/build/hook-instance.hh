#pragma once
///@file

#include "nix/util/logging.hh"
#include "nix/util/serialise.hh"
#include "nix/util/processes.hh"

#include <chrono>
#include <functional>
#include <memory>

namespace nix {

/**
 * @note Sometimes this is owned by the `Worker`, and sometimes it is
 * owned by a `Goal`. This is for efficiency: rather than starting the
 * hook every time we want to ask whether we can run a remote build
 * (which can be very often), we reuse a hook process for answering
 * those queries until it accepts a build.
 *
 * One hook decides at a time. The goal asking it owns it while it
 * waits for the reply (`Worker::hookBusy`); other goals that want the
 * hook queue in `Worker::wantingHook` rather than start their own. A
 * `decline` or `postpone` hands the hook back to `Worker::hook` for
 * the next goal; `accept` keeps it for the build, and the next goal
 * starts a fresh one. So besides the hook each accepted build takes
 * along, at most one more is alive.
 */
struct HookInstance
{
    /**
     * Pipes for talking to the build hook.
     */
    Pipe toHook;

    /**
     * Pipe for the hook's standard output/error.
     */
    Pipe fromHook;

    /**
     * Pipe for the builder's standard output/error.
     */
    Pipe builderOut;

    /**
     * The process ID of the hook.
     */
    Pid pid;

    FdSink sink;

    std::map<ActivityId, Activity> activities;

    /**
     * Callback to run when the hook process is killed in the destructor.
     * Used to call `Worker::childTerminated`.
     */
    std::function<void()> onKillChild;

    /**
     * Run the program named by the `build-hook` setting, in a child
     * process of this one. With the setting at its default there is no
     * hook process at all: the worker builds on remote machines itself
     * (`DerivationBuildingGoal::buildRemotely`).
     */
    static std::unique_ptr<HookInstance> external(const Strings & buildHook, std::chrono::milliseconds timeout);

    ~HookInstance();

private:

    /**
     * Creates the pipes.
     */
    HookInstance();

    /**
     * Take ownership of the started child and close its pipe ends.
     */
    void adopt(pid_t childPid, std::chrono::milliseconds timeout);
};

} // namespace nix

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
 * One goal at a time asks the hook, owning it until the reply; others
 * wait in `Worker::wantingHook`. After `decline` or `postpone` it goes
 * back to `Worker::hook`, and an accepted build keeps it. So apart from
 * those of accepted builds, at most one hook is alive.
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
     * A line from `fromHook` whose newline has not arrived yet, kept for
     * the next reader (`tryBuildHook`, then `buildWithHook`).
     */
    std::string partialLine;

    /**
     * Callback to run when the hook process is killed in the destructor.
     * Used to call `Worker::childTerminated`.
     */
    std::function<void()> onKillChild;

    /**
     * Start the program named by the `build-hook` setting. At its default,
     * `nix __build-remote`, it serves only machines that are not `ssh-ng`;
     * the worker builds on those itself.
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

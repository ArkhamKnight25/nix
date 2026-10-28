#include "nix/util/config-global.hh"
#include "nix/store/build/hook-instance.hh"
#include "nix/store/globals.hh"
#include "nix/util/strings.hh"
#include "nix/util/executable-path.hh"
#include "nix/util/current-process.hh"
#include "nix/util/util.hh"

#include <chrono>
#include <filesystem>
#include <optional>
#include <utility>

namespace nix {

HookInstance::HookInstance()
{
    /* Create a pipe to get the output of the child. */
    fromHook.create();

    /* Create the communication pipes. */
    toHook.create();

    /* Create a pipe to get the output of the builder. */
    builderOut.create();
}

void HookInstance::adopt(pid_t childPid, std::chrono::milliseconds timeout)
{
    pid = childPid;

    /* Give custom build hooks the chance to cleanup. */
    pid.setKillSignal(SIGTERM);
    pid.setKillTimeout(timeout);

    pid.setSeparatePG(true);
    fromHook.writeSide = -1;
    toHook.readSide = -1;

    sink = FdSink(toHook.writeSide.get());
}

std::unique_ptr<HookInstance> HookInstance::external(const Strings & _buildHook, std::chrono::milliseconds timeout)
{
    debug("starting build hook '%s'", concatStringsSep(" ", _buildHook));

    auto buildHookArgs = _buildHook;

    if (buildHookArgs.empty())
        throw Error("'build-hook' setting is empty");

    /* The default hook is this Nix's own `nix __build-remote`. Run the
       `nix` next to the running program, as upstream did by setting the
       absolute path as the default, rather than whatever `nix` comes first
       on PATH. The setting itself keeps its default value: the worker
       builds on ssh-ng machines in-process only when it is the default. */
    std::optional<std::filesystem::path> selfNix;
    if (buildHookArgs == Strings{"nix", "__build-remote"})
        if (auto self = getSelfExe()) {
            auto nix = self->parent_path() / "nix";
            if (std::filesystem::exists(nix))
                selfNix = nix;
        }

    std::filesystem::path buildHook = buildHookArgs.front();
    buildHookArgs.pop_front();

    if (selfNix)
        buildHook = *selfNix;
    else
        try {
            buildHook = ExecutablePath::load().findPath(buildHook);
        } catch (ExecutableLookupError & e) {
            e.addTrace(nullptr, "while resolving the 'build-hook' setting'");
            throw;
        }

    Strings args;

    for (auto & arg : buildHookArgs)
        args.push_back(arg);

    args.push_back(std::to_string(std::to_underlying(verbosity)));

    auto hook = std::unique_ptr<HookInstance>(new HookInstance());

    /* Fork the hook. */
    Pid childPid = spawnProgram(
        {
            .program = buildHook,
            .lookupPath = false,
            .args = args,
            .chdir = "/",
            /* Put the child in a separate session (and thus a separate
               process group) so that it has no controlling terminal (meaning
               that e.g. ssh cannot open /dev/tty) and it doesn't receive
               terminal signals. */
            .setSid = true,
            /* Build hook needs a writable store seemingly because it opens the default one?
               How is building in chroot stores supposed to work? */
            .restoreMounts = false,
        },
        std::to_array<FdRedirection>({
            /* These are the pipes for talking with the hook. */
            {.from = hook->toHook.readSide.get(), .to = FdRedirection::stdInput},
            {.from = hook->fromHook.writeSide.get(), .to = FdRedirection::stdOut},
            /* Merge stderr to stdout. */
            {.from = FdRedirection::stdOut, .to = FdRedirection::stdError},
            /* TODO: Can these redirections form a cycle? Do we need to dup them
               (potentially) out of the way first? */
            /* Use fd 4 for the builder's stdout/stderr. */
            {.from = hook->builderOut.writeSide.get(), .to = 4},
            /* Hack: pass the read side of that fd to allow build-remote
               to read SSH error messages. */
            {.from = hook->builderOut.readSide.get(), .to = 5},
        }));

    hook->adopt(childPid.release(), timeout);

    /* The hook is a fresh process with its own configuration, so tell
       it ours. */
    std::map<std::string, Config::SettingInfo> settingsToSend;
    globalConfig.getSettings(settingsToSend);
    for (auto & setting : settingsToSend)
        hook->sink << 1 << setting.first << setting.second.value;
    hook->sink << 0;

    return hook;
}

HookInstance::~HookInstance()
{
    try {
        toHook.writeSide = -1;
        if (pid != -1) {
            pid.kill();
            if (onKillChild)
                onKillChild();
        }
    } catch (...) {
        ignoreExceptionInDestructor();
    }
}

} // namespace nix

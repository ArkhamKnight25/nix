#include "nix/util/config-global.hh"
#include "nix/store/build/hook-instance.hh"
#include "nix/store/build/build-remote.hh"
#include "nix/store/build/child.hh"
#include "nix/store/globals.hh"
#include "nix/store/store-open.hh"
#include "nix/util/strings.hh"
#include "nix/util/executable-path.hh"

#include <chrono>
#include <utility>

namespace nix {

void HookInstance::redirectChildFds()
{
    if (dup2(fromHook.writeSide.get(), STDERR_FILENO) == -1)
        throw SysError("cannot pipe standard error into log file");

    commonChildInit();

    if (chdir("/") == -1)
        throw SysError("changing into /");

    /* Dup the communication pipes. */
    if (dup2(toHook.readSide.get(), STDIN_FILENO) == -1)
        throw SysError("dupping to-hook read side");

    /* Use fd 4 for the builder's stdout/stderr. */
    if (dup2(builderOut.writeSide.get(), 4) == -1)
        throw SysError("dupping builder's stdout/stderr");

    /* Hack: pass the read side of that fd to allow the hook to read
       SSH error messages. */
    if (dup2(builderOut.readSide.get(), 5) == -1)
        throw SysError("dupping builder's stdout/stderr");
}

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

    std::filesystem::path buildHook = buildHookArgs.front();
    buildHookArgs.pop_front();

    try {
        buildHook = ExecutablePath::load().findPath(buildHook);
    } catch (ExecutableLookupError & e) {
        e.addTrace(nullptr, "while resolving the 'build-hook' setting'");
        throw;
    }

    Strings args;
    args.push_back(buildHook.filename().string());

    for (auto & arg : buildHookArgs)
        args.push_back(arg);

    args.push_back(std::to_string(std::to_underlying(verbosity)));

    auto hook = std::unique_ptr<HookInstance>(new HookInstance());

    /* Fork the hook. */
    auto childPid = startProcess([&]() {
        hook->redirectChildFds();

        execv(requireCString(buildHook.native()), stringsToCharPtrs(args).data());

        throw SysError("executing %s", PathFmt(buildHook));
    });

    hook->adopt(childPid, timeout);

    /* The hook is a fresh process with its own configuration, so tell
       it ours. */
    std::map<std::string, Config::SettingInfo> settingsToSend;
    globalConfig.getSettings(settingsToSend);
    for (auto & setting : settingsToSend)
        hook->sink << 1 << setting.first << setting.second.value;
    hook->sink << 0;

    return hook;
}

std::unique_ptr<HookInstance> HookInstance::builtin(std::chrono::milliseconds timeout)
{
    debug("starting the built-in build hook");

    auto hook = std::unique_ptr<HookInstance>(new HookInstance());

    auto childPid = startProcess([&]() {
        hook->redirectChildFds();

        /* The parent parses our log output, so it has to be JSON.
           `commonChildInit` has just replaced the logger with a plain
           one. */
        logger = makeJSONLogger(getStandardError()).release();

        /* Ensure we don't get any SSH passphrase or host key popups. */
        unsetenv("DISPLAY");
        unsetenv("SSH_ASKPASS");

        /* `nix __build-remote` does this once it has read the settings
           we would otherwise have sent it. We are a fork, so we already
           have them, and the `max-jobs` override is process-local and
           cannot reach the parent. */
        unsigned int maxBuildJobs = settings.getWorkerSettings().maxBuildJobs.get();
        settings.getWorkerSettings().maxBuildJobs.set("1"); // hack to make tests with local?root= work

        /* Open the store afresh rather than reusing the parent's: a
           forked child must not share its SQLite connection or its
           temp-roots file. `daemon.cc` reopens for the same reason. */
        FdSource source(STDIN_FILENO);
        serveBuildHook(openStore(), maxBuildJobs, source, STDERR_FILENO, 5);

        _exit(0);
    });

    hook->adopt(childPid, timeout);

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

#include "nix/util/config-global.hh"
#include "nix/store/build/hook-instance.hh"
#include "nix/store/build/build-remote.hh"
#include "nix/store/build/child.hh"
#include "nix/store/globals.hh"
#include "nix/store/store-api.hh"
#include "nix/util/strings.hh"
#include "nix/util/executable-path.hh"

#include <chrono>
#include <utility>

#include <unistd.h>

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

/* Close every inherited descriptor except the five the protocol uses.
   `O_CLOEXEC` did this for the exec'd hook; a fork keeps them, and the
   copies would pin the parent's `PathLocks`, which release by `close()`
   alone. `unix::closeExtraFDs()` keeps only 0-2, which would take the
   builder-output pipes on 4 and 5 with it. */
static void closeExtraHookFDs()
{
    close(3);
    for (int fd = 6, maxFd = static_cast<int>(sysconf(_SC_OPEN_MAX)); fd < maxFd; ++fd)
        close(fd);
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

std::unique_ptr<HookInstance> HookInstance::builtin(const StoreConfig & storeConfig, std::chrono::milliseconds timeout)
{
    debug("starting the built-in build hook");

    auto hook = std::unique_ptr<HookInstance>(new HookInstance());

    auto childPid = startProcess([&]() {
        hook->redirectChildFds();
        closeExtraHookFDs();

        /* The parent parses our output, so it has to be JSON. */
        logger = makeJSONLogger(getStandardError()).release();

        /* Ensure we don't get any SSH passphrase or host key popups. */
        unsetenv("DISPLAY");
        unsetenv("SSH_ASKPASS");

        /* As `nix __build-remote` does after reading our settings; we
           are a fork, so we have them already. */
        unsigned int maxBuildJobs = settings.getWorkerSettings().maxBuildJobs.get();
        settings.getWorkerSettings().maxBuildJobs.set("1"); // hack to make tests with local?root= work

        /* SQLite forbids using a connection across a fork, and we write
           through the store. Open from the config we were handed rather
           than the ambient URI, which can name a different store. */
        auto store = storeConfig.openStore();
        store->init();

        FdSource source(STDIN_FILENO);
        serveBuildHook(store, maxBuildJobs, source, STDERR_FILENO, 5);

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

#include "nix/store/build/remote-machine-build.hh"
#include "nix/store/build.hh"
#include "nix/store/globals.hh"
#include "nix/store/local-store.hh"
#include "nix/store/remote-store.hh"
#include "nix/store/ssh-store.hh"
#include "nix/store/worker-protocol.hh"
#include "nix/store/store-open.hh"
#include "nix/util/experimental-features.hh"
#include "nix/util/finally.hh"
#include "nix/util/util.hh"

#include <boost/asio/steady_timer.hpp>

#include <array>
#include <optional>
#include <ranges>
#include <thread>

#include <unistd.h>

namespace nix {

/**
 * Reads what a legacy `ssh://` machine writes to ssh's stderr, which is
 * the remote build's log, and hands it to `sink`, as the hook's parent
 * did from the pipe on the hook's descriptor 4. A thread of its own does
 * the reading: that store blocks the worker's thread for the whole of
 * `buildDerivation`, so nothing else could, and the ssh child would
 * stall once the pipe filled. The write side goes to the store as
 * `log-fd` and is inherited by its ssh children as their stderr;
 * destroying this closes our copy and waits for the reader, which ends
 * when the last child holding one has gone. Destroy it after the store.
 */
struct RawLogDrain
{
    Pipe pipe;
    std::thread reader;

    RawLogDrain(std::function<void(std::string_view)> sink)
    {
        pipe.create();
        reader = std::thread([fd = pipe.readSide.get(), sink = std::move(sink)]() {
            try {
                std::array<char, 4096> buf;
                while (true) {
                    ssize_t n = ::read(fd, buf.data(), buf.size());
                    if (n == 0)
                        break;
                    if (n == -1) {
                        if (errno == EINTR)
                            continue;
                        break;
                    }
                    sink(std::string_view(buf.data(), n));
                }
            } catch (...) {
                ignoreExceptionInDestructor();
            }
        });
    }

    ~RawLogDrain()
    {
        pipe.writeSide.close();
        if (reader.joinable())
            reader.join();
    }
};

/**
 * Open the machine's store for use from this coroutine. Only `ssh-ng`
 * knows how to suspend instead of block; any other kind (the legacy
 * `ssh://`, a local store) is opened as usual and blocks the worker
 * while it is talked to. `mounted-ssh-ng` has its own store class and
 * is left to the blocking path too.
 *
 * `rawLog` is created on demand for a machine whose build log arrives
 * as bytes, and reused for the next such machine.
 */
static ref<Store> openMachineStore(
    const RemoteMachineBuildRequest & req,
    const Machine & machine,
    std::unique_ptr<RawLogDrain> & rawLog,
    bool & blocking,
    asio::io_context & ctx,
    asio::yield_context yield)
{
    auto storeUri = machine.completeStoreReference();

    /* `Machine::completeStoreReference` points the legacy `ssh://`
       store's `log-fd` at descriptor 4: the hook's pipe to its parent,
       where ssh's stderr, carrying the remote build's log, was read by
       the parent and written into the log file. Here that pipe is ours.
       Left unset, ssh's stderr would be inherited (`SSHMaster::startCommand`
       redirects it only when `logFD` is given) and the build's output
       would land raw on the worker's stderr, around the logger. */
    if (storeUri.params.contains("log-fd")) {
        if (req.rawBuildOutput) {
            if (!rawLog)
                rawLog = std::make_unique<RawLogDrain>(req.rawBuildOutput);
            storeUri.params["log-fd"] = std::to_string(rawLog->pipe.writeSide.get());
        } else
            storeUri.params.erase("log-fd");
    }

    auto config = resolveStoreConfig(std::move(storeUri));
    if (!config.dynamic_pointer_cast<const MountedSSHStoreConfig>())
        if (auto sshConfig = config.dynamic_pointer_cast<const SSHStoreConfig>()) {
            blocking = false;
            return sshConfig->openStoreAsync(ctx, yield, req.messageLogger);
        }
    blocking = true;
    warn(
        "remote builder '%s' is not an ssh-ng store; talking to it will hold up other builds",
        machine.storeUri.render());
    return config->openStore();
}

/**
 * The hook process set `max-jobs` to 1 before it opened the machine's
 * store, so that a client running with `-j0` could still build on a
 * machine that builds in this process (`auto`, `local?root=`), or on a
 * local daemon, which takes the client's `max-jobs` when it connects.
 * Here the setting belongs to the whole process, so it is raised only
 * around calls on such a store, which do not yield to the worker.
 */
struct MachineMaxBuildJobs
{
    unsigned int saved = settings.getWorkerSettings().maxBuildJobs.get();

    MachineMaxBuildJobs()
    {
        settings.getWorkerSettings().maxBuildJobs.assign(1);
    }

    ~MachineMaxBuildJobs()
    {
        settings.getWorkerSettings().maxBuildJobs.assign(saved);
    }
};

/**
 * The hook waited for the upload lock with `alarm(15 * 60)` around a
 * blocking `lockFile`. Here the wait must not block the thread: try the
 * lock, sleep on the loop, repeat, and give up after the same fifteen
 * minutes.
 */
static void
acquireUploadLock(Descriptor lock, std::string_view storeUri, asio::io_context & ctx, asio::yield_context yield)
{
    Activity act(*logger, lvlTalkative, actUnknown, fmt("waiting for the upload lock to '%s'", storeUri));

    auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(15);
    while (!lockFile(lock, ltWrite, false)) {
        if (std::chrono::steady_clock::now() >= deadline) {
            printError("somebody is hogging the upload lock for '%s', continuing...", storeUri);
            return;
        }
        asio::steady_timer timer(ctx, std::chrono::seconds(1));
        boost::system::error_code ec;
        timer.async_wait(yield[ec]);
        if (ec)
            /* Cancellation arrives here when we are between network operations. */
            throw SystemError(ec, "waiting for the upload lock to '%s'", storeUri);
    }
}

RemoteMachineBuildOutcome buildOnRemoteMachine(
    Store & store,
    Machines & machines,
    AcquiredMachine acquired,
    const RemoteMachineBuildRequest & req,
    asio::io_context & ctx,
    asio::yield_context yield)
{
    /* Cancelled before this first ran: the goal went away between the
       spawn and the loop's next turn. Do not start an ssh child only to
       tear it down again; the first operation would fail anyway. */
    if (yield.cancelled() != asio::cancellation_type::none)
        throw SystemError(boost::system::error_code(asio::error::operation_aborted), "remote build cancelled");

    /* A terminal cancellation (the goal went away, or the log limit was
       hit) is delivered once, to the operation pending at that moment. An
       operation that had already completed, or one started afterwards (a
       destructor flushing during unwinding), would not see it and could
       wait forever. With this set, every operation started after the
       cancellation fails at once. It must be off again before the
       coroutine completes. */
    yield.throw_if_cancelled(true);
    Finally noLongerThrowIfCancelled([&] { yield.throw_if_cancelled(false); });

    auto currentLoad = getCurrentLoadDir(store);

    /* Connect, moving on to the next machine when one cannot be
       reached, as `serveBuildHook` does. The drain is declared before
       the store so that it is destroyed after it, once the ssh children
       writing to it are gone. */
    std::unique_ptr<RawLogDrain> rawLog;
    std::shared_ptr<Store> sshStore;
    bool blocking = false;
    std::string storeUri;
    while (true) {
        storeUri = acquired.machine->storeUri.render();
        try {
            Activity act(*logger, lvlTalkative, actUnknown, fmt("connecting to '%s'", storeUri));
            sshStore = openMachineStore(req, *acquired.machine, rawLog, blocking, ctx, yield);
            std::optional<MachineMaxBuildJobs> maxBuildJobs;
            if (blocking)
                maxBuildJobs.emplace();
            sshStore->connect();
            break;
        } catch (Interrupted &) {
            throw;
        } catch (std::exception & e) {
            /* A cancelled coroutine fails its operation with
               `operation_aborted`; that is not the machine's fault. */
            if (yield.cancelled() != asio::cancellation_type::none)
                throw;
            /* The hook also showed ssh's own stderr here, which it had
               on a pipe; ours goes wherever the worker's stderr goes. */
            printError("cannot build on '%s': %s", storeUri, e.what());
            acquired.machine->enabled = false;
        }

        acquired.slotLock.close();
        auto selection = acquireMachineSlot(currentLoad, machines, req.neededSystem, req.requiredFeatures);
        if (auto * noMachine = std::get_if<NoMachine>(&selection))
            return RemoteMachineUnavailable{*noMachine};
        acquired = std::get<AcquiredMachine>(std::move(selection));
    }

    AutoCloseFD uploadLock = openUploadLock(currentLoad, storeUri);
    acquireUploadLock(uploadLock.get(), storeUri, ctx, yield);

    auto substitute = settings.getWorkerSettings().buildersUseSubstitutes ? Substitute : NoSubstitute;

    /* An `ssh-ng` machine's connection streams belong to this coroutine
       and must be used from its thread only (see `AsyncFdSource`). The
       upload stays on this thread because `RemoteStore::addMultipleToStore`
       sends the paths one after another on the calling thread, for a
       daemon of protocol 1.32 or newer; older daemons get the base
       class's threaded implementation, which would write to the
       connection from pool threads. Copy one path at a time for those. */
    auto copyToMachine = [&](const StorePathSet & paths) {
        auto * remote = dynamic_cast<RemoteStore *>(&*sshStore);
        if (remote
            && WorkerProto::Version::Number::fromWire(remote->getProtocol()) < WorkerProto::Version::Number{1, 32})
            for (auto & path : store.topoSortPaths(paths) | std::views::reverse)
                copyStorePath(store, *sshStore, path, NoRepair, NoCheckSigs);
        else
            copyPaths(store, *sshStore, paths, NoRepair, NoCheckSigs, substitute);
    };

    {
        Activity act(*logger, lvlTalkative, actUnknown, fmt("copying dependencies to '%s'", storeUri));
        copyToMachine(req.inputPaths);
    }

    uploadLock.close();

    auto & drv = *req.drv;

    BuildResult result;

    // If we don't know whether we are trusted (e.g. `ssh://`
    // stores), we assume we are. This is necessary for backwards
    // compat.
    bool trustedOrLegacy = ({
        std::optional trusted = sshStore->isTrustedClient();
        !trusted || *trusted;
    });

    // See the very large comment in `case WorkerProto::Op::BuildDerivation:` in
    // `src/libstore/daemon.cc` that explains the trust model here.
    //
    // This condition mirrors that: that code enforces the "rules" outlined there;
    // we do the best we can given those "rules".
    std::optional<MachineMaxBuildJobs> maxBuildJobs;
    if (blocking)
        maxBuildJobs.emplace();
    if (trustedOrLegacy || type(drv).isCA()) {
        /* `req.drv` already carries its input derivations' outputs as
           input sources, which is the derivation `serveBuildHook`
           reconstructs at this point. */
        result = sshStore->getBuilder()->buildDerivation(req.drvPath, drv);
    } else {
        /* `copyClosure` would reach the threaded `addMultipleToStore`
           for an older daemon, as above. */
        StorePathSet closure;
        store.computeFSClosure(StorePathSet{req.drvPath}, closure);
        copyToMachine(closure);
        auto res = sshStore->getBuilder()->buildPathsWithResults({DerivedPath::Built{
            .drvPath = makeConstantStorePathRef(req.drvPath),
            .outputs = OutputsSpec::All{},
        }});
        // One path to build should produce exactly one build result
        assert(res.size() == 1);
        result = std::move(res[0]);
    }
    maxBuildJobs.reset();

    if (result.tryGetFailure()) {
        if (settings.keepFailed)
            warn(
                "The failed build directory was kept on the remote builder due to `--keep-failed`.%s",
                (settings.thisSystem == drv.platform || settings.extraPlatforms.get().count(drv.platform) > 0)
                    ? " You can re-run the command with `--builders ''` to disable remote building for this invocation."
                    : "");
        return RemoteMachineBuilt{storeUri, std::move(result)};
    }

    std::set<Realisation> missingRealisations;
    StorePathSet missingPaths;
    if (experimentalFeatureSettings.isEnabled(Xp::CaDerivations) && !type(drv).hasKnownOutputPaths()) {
        for (auto & outputName : req.wantedOutputs) {
            auto thisOutputId = DrvOutput{req.drvPath, outputName};
            if (!store.queryRealisation(thisOutputId)) {
                debug("missing output %s", outputName);
                auto * success = result.tryGetSuccess();
                assert(success);
                auto i = success->builtOutputs.find(outputName);
                assert(i != success->builtOutputs.end());
                auto & newRealisation = i->second;
                missingRealisations.insert({newRealisation, thisOutputId});
                missingPaths.insert(newRealisation.outPath);
            }
        }
    } else {
        auto outputPaths = outputsAndOptPaths(drv, store);
        for (auto & [outputName, hopefullyOutputPath] : outputPaths) {
            assert(hopefullyOutputPath.second);
            if (!store.isValidPath(*hopefullyOutputPath.second))
                missingPaths.insert(*hopefullyOutputPath.second);
        }
    }

    if (!missingPaths.empty()) {
        Activity act(*logger, lvlTalkative, actUnknown, fmt("copying outputs from '%s'", storeUri));

        /* The goal holds the output paths' locks; `LocalStore::addToStore`
           must not try to take them again. The hook left them in
           `locksHeld` because its process ended here; we are not so
           lucky. */
        auto * localStore = dynamic_cast<LocalStore *>(&store);
        Finally releaseLocksHeld([&] {
            if (localStore)
                for (auto & path : missingPaths)
                    localStore->locksHeld.erase(store.printStorePath(path));
        });
        if (localStore)
            for (auto & path : missingPaths)
                localStore->locksHeld.insert(store.printStorePath(path)); /* FIXME: ugly */

        /* Not `copyPaths`: it hands the paths to `store.addMultipleToStore`,
           which on a local store runs them through a `ThreadPool` whose
           extra threads would read from the machine's connection, an
           `AsyncFdSource` tied to this coroutine and its thread (the pool
           grows as soon as two paths are pending, so any derivation with
           two missing outputs). One path at a time, references first, as
           `copyPaths` orders them. */
        for (auto & path : sshStore->topoSortPaths(missingPaths) | std::views::reverse)
            copyStorePath(*sshStore, store, path, NoRepair, NoCheckSigs);
    }

    // XXX: Should be done as part of `copyPaths`
    for (auto & realisation : missingRealisations) {
        // Should hold, because if the feature isn't enabled the set
        // of missing realisations should be empty
        experimentalFeatureSettings.require(Xp::CaDerivations);
        store.registerDrvOutput(realisation, NoCheckSigs);
    }

    return RemoteMachineBuilt{storeUri, std::move(result)};
}

} // namespace nix

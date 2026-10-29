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
 * Open the machine's store from this coroutine. Only an `ssh-ng` store
 * can suspend instead of block, so `machineRunsInProcess` sends every
 * other kind to the hook.
 */
static ref<Store> openMachineStore(
    const RemoteMachineBuildRequest & req, const Machine & machine, asio::io_context & ctx, asio::yield_context yield)
{
    auto storeUri = machine.completeStoreReference();
    /* `Machine::completeStoreReference` points a legacy `ssh://` store's
       `log-fd` at the hook's descriptor 4, which does not exist here. */
    storeUri.params.erase("log-fd");

    auto config = resolveStoreConfig(std::move(storeUri));
    auto sshConfig = config.dynamic_pointer_cast<const SSHStoreConfig>();
    if (!sshConfig || config.dynamic_pointer_cast<const MountedSSHStoreConfig>())
        throw Error("remote builder '%s' is not an ssh-ng store", machine.storeUri.render());
    return sshConfig->openStoreAsync(ctx, yield, req.messageLogger);
}

bool machineRunsInProcess(const Machine & machine)
{
    try {
        auto config = resolveStoreConfig(machine.completeStoreReference());
        return !config.dynamic_pointer_cast<const MountedSSHStoreConfig>()
               && config.dynamic_pointer_cast<const SSHStoreConfig>();
    } catch (Error &) {
        /* Let the hook report it. */
        return false;
    }
}

/**
 * Wait up to fifteen minutes for the upload lock, as the hook did, but
 * without blocking the worker thread.
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
        {
            SuspendedActivity suspended;
            timer.async_wait(yield[ec]);
        }
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
    /* The goal went away before this first ran; do not start an ssh
       child only to tear it down again. */
    if (yield.cancelled() != asio::cancellation_type::none)
        throw SystemError(boost::system::error_code(asio::error::operation_aborted), "remote build cancelled");

    /* A terminal cancellation reaches only the operation pending at that
       moment. Make every later one (a destructor flushing while unwinding,
       say) fail at once instead of waiting forever. This must be off again
       before the coroutine completes. */
    yield.throw_if_cancelled(true);
    Finally noLongerThrowIfCancelled([&] { yield.throw_if_cancelled(false); });

    auto currentLoad = getCurrentLoadDir(store);

    /* Connect, moving on to the next machine when one cannot be
       reached, as `serveBuildHook` does. */
    std::shared_ptr<Store> sshStore;
    std::string storeUri;
    while (true) {
        storeUri = acquired.machine->storeUri.render();
        try {
            Activity act(*logger, lvlTalkative, actUnknown, fmt("connecting to '%s'", storeUri));
            sshStore = openMachineStore(req, *acquired.machine, ctx, yield);
            sshStore->connect();
            break;
        } catch (Interrupted &) {
            throw;
        } catch (std::exception & e) {
            /* A cancellation is not the machine's fault. */
            if (yield.cancelled() != asio::cancellation_type::none)
                throw;
            /* ssh's own stderr goes straight to the worker's. */
            printError("cannot build on '%s': %s", storeUri, e.what());
            acquired.machine->enabled = false;
        }

        acquired.slotLock.close();
        auto selection = acquireMachineSlot(currentLoad, machines, req.neededSystem, req.requiredFeatures);
        if (auto * noMachine = std::get_if<NoMachine>(&selection))
            return RemoteMachineUnavailable{*noMachine};
        acquired = std::get<AcquiredMachine>(std::move(selection));
        /* For a machine that is not `ssh-ng`, give the slot back: the goal
           asks again, and `tryRemoteBuilder` sends it to the hook. */
        if (!machineRunsInProcess(*acquired.machine))
            return RemoteMachineUnavailable{NoMachine::AllBusy};
    }

    AutoCloseFD uploadLock = openUploadLock(currentLoad, storeUri);
    acquireUploadLock(uploadLock.get(), storeUri, ctx, yield);

    auto substitute = settings.getWorkerSettings().buildersUseSubstitutes ? Substitute : NoSubstitute;

    /* The connection must only be used from this coroutine's thread.
       `RemoteStore::addMultipleToStore` stays on the calling thread only
       for a daemon of protocol 1.32 or newer; older ones get the base
       class's threaded version, so copy to them one path at a time. */
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
    if (trustedOrLegacy || type(drv).isCA()) {
        /* `req.drv` already has its input derivations' outputs among its
           input sources. */
        result = sshStore->getBuilder()->buildDerivation(req.drvPath, drv);
    } else {
        /* Not `copyClosure`, for the same reason as above. */
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

        /* The goal holds the outputs' locks, so `LocalStore::addToStore`
           must not take them again. `locksHeld` is process-wide and the
           copy suspends, so keep each path in it only while it is copied. */
        auto * localStore = dynamic_cast<LocalStore *>(&store);

        /* Not `copyPaths`: a local store's `addMultipleToStore` would read
           the connection from `ThreadPool` threads. Copy one path at a
           time, references first. */
        for (auto & path : sshStore->topoSortPaths(missingPaths) | std::views::reverse) {
            auto printed = store.printStorePath(path);
            if (localStore)
                localStore->locksHeld.lock()->insert(printed); /* FIXME: ugly */
            Finally releaseLockHeld([&] {
                if (localStore)
                    localStore->locksHeld.lock()->erase(printed);
            });
            copyStorePath(*sshStore, store, path, NoRepair, NoCheckSigs);
        }
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

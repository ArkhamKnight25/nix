#include "nix/store/build/remote-machine-build.hh"
#include "nix/store/globals.hh"
#include "nix/store/local-store.hh"
#include "nix/store/ssh-store.hh"
#include "nix/store/store-open.hh"
#include "nix/util/experimental-features.hh"
#include "nix/util/finally.hh"

#include <boost/asio/steady_timer.hpp>

namespace nix {

/**
 * Open the machine's store for use from this coroutine. Only `ssh-ng`
 * knows how to suspend instead of block; any other kind (the legacy
 * `ssh://`, a local store) is opened as usual and blocks the worker
 * while it is talked to. `mounted-ssh-ng` has its own store class and
 * is left to the blocking path too.
 */
static ref<Store> openMachineStore(const RemoteMachineBuildRequest & req, const Machine & machine, asio::io_context & ctx, asio::yield_context yield)
{
    auto storeUri = machine.completeStoreReference();
    /* The hook had the legacy `ssh://` store write the build log to its
       descriptor 4, the pipe to the hook's parent. Inside the worker
       descriptor 4 is whatever it happens to be; those logs are not
       collected yet. */
    storeUri.params.erase("log-fd");

    auto config = resolveStoreConfig(std::move(storeUri));
    if (!config.dynamic_pointer_cast<const MountedSSHStoreConfig>())
        if (auto sshConfig = config.dynamic_pointer_cast<const SSHStoreConfig>())
            return sshConfig->openStoreAsync(ctx, yield, req.messageLogger);
    warn(
        "remote builder '%s' is not an ssh-ng store; talking to it will hold up other builds",
        machine.storeUri.render());
    return config->openStore();
}

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

    {
        Activity act(*logger, lvlTalkative, actUnknown, fmt("copying dependencies to '%s'", storeUri));
        copyPaths(store, *sshStore, req.inputPaths, NoRepair, NoCheckSigs, substitute);
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
        /* `req.drv` already carries its input derivations' outputs as
           input sources, which is the derivation `serveBuildHook`
           reconstructs at this point. */
        result = sshStore->getBuilder()->buildDerivation(req.drvPath, drv);
    } else {
        copyClosure(store, *sshStore, StorePathSet{req.drvPath}, NoRepair, NoCheckSigs, substitute);
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

        copyPaths(*sshStore, store, missingPaths, NoRepair, NoCheckSigs, NoSubstitute);
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

#pragma once
///@file

#include "nix/store/build-result.hh"
#include "nix/store/realisation.hh"
#include "nix/store/store-api.hh"
#include "nix/util/file-descriptor.hh"
#include "nix/util/serialise.hh"

#include <set>

namespace nix {

/**
 * Whether `remote` trusts us. If it cannot tell (e.g. `ssh://` stores),
 * we assume it does, for backwards compatibility.
 *
 * See the very large comment in `case WorkerProto::Op::BuildDerivation:`
 * in `src/libstore/daemon.cc` that explains the trust model here.
 */
bool trustedOrLegacy(Store & remote);

/**
 * With `--keep-failed`, tell the user that the failed build directory
 * stayed on the remote builder.
 */
void warnIfKeptFailedRemotely(const std::string & platform);

struct MissingOutputs
{
    StorePathSet paths;
    std::set<Realisation> realisations;
};

/**
 * The outputs of `drv` that the build on `storeUri` produced and `store`
 * does not have yet.
 */
template<typename Drv>
MissingOutputs findMissingOutputs(
    Store & store,
    const StorePath & drvPath,
    const Drv & drv,
    const StringSet & wantedOutputs,
    const BuildResult & result,
    std::string_view storeUri);

void registerRealisations(Store & store, const std::set<Realisation> & realisations);

/**
 * The build hook: answer requests from `from` on `toParent` and run
 * an accepted build on a machine from `builders`. Returns at EOF or
 * after one accepted build.
 *
 * @param maxBuildJobs the parent's `max-jobs`.
 * @param sshErrorFd ssh's stderr, read when a connection fails.
 */
void serveBuildHook(
    ref<Store> store, unsigned int maxBuildJobs, Source & from, Descriptor toParent, Descriptor sshErrorFd);

} // namespace nix

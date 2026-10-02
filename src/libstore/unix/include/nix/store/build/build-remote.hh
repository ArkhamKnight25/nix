#pragma once
///@file

#include "nix/store/store-api.hh"
#include "nix/util/file-descriptor.hh"
#include "nix/util/serialise.hh"

namespace nix {

/**
 * Nix's own build hook: speak the build-hook protocol on `from` and
 * `toParent`, dispatching accepted builds to one of the machines named
 * by the `builders` setting.
 *
 * This is the body of `nix __build-remote`, which the `build-hook`
 * setting points at by default. It runs in a child process of the Nix
 * that wants the build.
 *
 * Returns once `from` reaches EOF or yields a word other than `"try"`,
 * or once one accepted build has finished and its outputs have been
 * copied into `store`.
 *
 * @param store the store the build is for. Inputs are read from it and
 * outputs are copied back into it.
 *
 * @param maxBuildJobs how many builds the parent can run itself. Only
 * used to decide whether declining is safe, so it is passed separately
 * from the rest of the settings, which the caller has already applied
 * globally.
 *
 * @param from the parent's requests.
 *
 * @param toParent the control channel back to the parent: the machine
 * name line and the `# accept` / `# decline` / `# postpone` /
 * `# decline-permanently` replies. Writes are unbuffered, because the
 * parent blocks on each reply and because the logger writes to the same
 * place.
 *
 * @param sshErrorFd ssh's standard error, drained without blocking when
 * a connection fails so its complaint can be reported, and closed once a
 * build is accepted.
 */
void serveBuildHook(
    ref<Store> store, unsigned int maxBuildJobs, Source & from, Descriptor toParent, Descriptor sshErrorFd);

} // namespace nix

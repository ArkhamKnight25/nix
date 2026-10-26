---
synopsis: "Builds on `ssh-ng` machines no longer start a build hook process"
---

With the default [`build-hook`](@docroot@/command-ref/conf-file.md#conf-build-hook), Nix now builds on [`ssh-ng`](@docroot@/store/types/ssh-store.md) machines itself instead of starting a `nix __build-remote` process for each build.
The daemon (or the client, when there is no daemon) drives all its remote builds from one process and keeps running its other builds meanwhile.
Other machine types (`ssh://`, local stores) and custom `build-hook` programs still go through the hook, with the same protocol, and Nix no longer blocks while it waits for the hook's reply.

For `ssh-ng` machines:

- A remote build that fails is reported with the remote machine's own failure status, so `nix-build` exits with 100, 101 or 102 as it does for a local failure.
  The hook flattened every remote failure to a generic one (exit code 1).
- A builder that cannot be reached is disabled for the rest of the invocation, as the hook disabled it for its own lifetime.
- `ssh` runs with `-oBatchMode=yes` for these connections: it fails rather than prompts.
  A builder's key must not need a passphrase, or must be in an agent, as the manual already asks; the hook could never prompt either.

A program named by `build-hook` is still run, with the same protocol.
While it chose a machine and connected to it, Nix could not start a local build or notice one finishing; its reply is now awaited while the other builds proceed.
It is consulted for one derivation at a time, and `decline-permanently` still stops Nix from consulting it again for the rest of the invocation.

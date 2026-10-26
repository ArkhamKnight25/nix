---
synopsis: "Remote builds on `ssh-ng` machines run inside the building process; a `build-hook` program no longer stalls other builds"
---

With [`build-hook`](@docroot@/command-ref/conf-file.md#conf-build-hook) at its default, Nix no longer starts a `nix __build-remote` child for a build on an [`ssh-ng`](@docroot@/store/types/ssh-store.md) machine.
The building process (the daemon, or the client when it builds for a store without one) selects the machine and drives the build over its own connection, and keeps running its other builds and substitutions meanwhile.
Machines of other kinds (`ssh://`, local stores) are still built on through `nix __build-remote`, whose reply is now awaited while the other builds proceed.

What changes for the user, for `ssh-ng` machines:

- A remote build that fails is reported with the remote machine's own failure status, so `nix-build` exits with 100, 101 or 102 as it does for a local failure.
  The hook flattened every remote failure to a generic one (exit code 1).
- A builder that cannot be reached is disabled for the rest of the invocation, as the hook disabled it for its own lifetime.
- `ssh` runs with `-oBatchMode=yes` for these connections: it fails rather than prompts.
  A builder's key must not need a passphrase, or must be in an agent, as the manual already asks; the hook could never prompt either.

A program named by `build-hook` is still run, with the same protocol.
While it chose a machine and connected to it, Nix could not start a local build or notice one finishing; its reply is now awaited while the other builds proceed.
It is consulted for one derivation at a time, and `decline-permanently` still stops Nix from consulting it again for the rest of the invocation.

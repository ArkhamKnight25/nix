---
synopsis: "Builds on `ssh-ng` machines no longer start a build hook process"
---

With the default [`build-hook`](@docroot@/command-ref/conf-file.md#conf-build-hook), Nix now builds on [`ssh-ng`](@docroot@/store/types/ssh-store.md) machines itself instead of starting a `nix __build-remote` process for each build.
The process that runs the builds (with a daemon, the process the daemon starts for each client connection; otherwise the client itself) drives its remote builds directly and keeps running its other builds meanwhile.
Other machine types (`ssh://`, local stores) and custom `build-hook` programs still go through the hook, with the same protocol, and Nix no longer blocks while it waits for the hook's reply.
To send `ssh-ng` builds through the hook as before, set `build-hook` to an absolute path of `nix __build-remote`, for example `build-hook = /path/to/bin/nix __build-remote`: any value other than the default is run as the hook for every remote build.

For `ssh-ng` machines:

- A failed remote build keeps the remote's failure status, so `nix-build` exits with the same code as for a local failure (100 when the builder fails) instead of 1.
  There are two exceptions: a hash mismatch on the remote machine still exits with 1, because the protocol reports it as a rejected output, and 101 (timeout) only appears when the remote machine's own configuration times the build out.
- A machine that cannot be reached is skipped for the rest of that build; later builds try it again.
- Each build opens its own `ssh` connection; connection sharing (`ControlMaster`) is not used.
- `ssh` runs with `-oBatchMode=yes` and fails instead of prompting, so a builder's key must work without a passphrase prompt (for example through an agent).

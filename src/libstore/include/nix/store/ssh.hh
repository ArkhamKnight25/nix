#pragma once
///@file

#include "nix/util/ref.hh"
#include "nix/util/sync.hh"
#include "nix/util/url.hh"
#include "nix/util/processes.hh"
#include "nix/util/file-system.hh"
#include "nix/util/logging.hh"

namespace nix {

/**
 * The ssh program used for all ssh invocations (build-time configurable
 * via the `ssh-program` option; either a name resolved via PATH or an
 * absolute path).
 */
const std::filesystem::path & sshProgram();

OsStrings getNixSshOpts();

class SSHMaster
{
private:

    ParsedURL::Authority authority;
    std::string hostnameAndUser;
    bool fakeSSH;
    const std::optional<std::filesystem::path> keyFile;
    /**
     * Raw bytes, not Base64 encoding.
     */
    const std::string sshPublicHostKey;
    const bool useMaster;
    const bool compress;
    /**
     * Pass `-oBatchMode=yes`: ssh fails instead of prompting. See the
     * constructor.
     */
    const bool batchMode;
    const Descriptor logFD;

    const ref<const AutoDelete> tmpDir;

    struct State
    {
        Pid sshMaster;
        std::filesystem::path socketPath;
    };

    Sync<State> state_;

    void addCommonSSHOpts(OsStrings & args);
    bool isMasterRunning();

    std::filesystem::path startMaster();

public:

    /**
     * @param batchMode Whether ssh may prompt. A connection the worker
     * drives from inside a coroutine (`SSHStoreConfig::openStoreAsync`)
     * must not: the worker's thread would sit in ssh's prompt while
     * every other goal waits, and the goal's own wait for the
     * `started` line suspends with the prompt half drawn. The build
     * hook ran ssh under `setsid` with no `DISPLAY` or `SSH_ASKPASS`,
     * so it could never prompt either; `-oBatchMode=yes` makes ssh fail
     * at once instead, with its reason on stderr.
     */
    SSHMaster(
        const ParsedURL::Authority & authority,
        std::optional<std::filesystem::path> keyFile,
        std::string_view sshPublicHostKey,
        bool useMaster,
        bool compress,
        Descriptor logFD = INVALID_DESCRIPTOR,
        bool batchMode = false);

    struct Connection
    {
        Pid sshPid;
        AutoCloseFD out, in;

        /**
         * Set when `startCommand` was told not to wait for ssh's
         * `started` line: the caller must read that line from `out`
         * before anything else, and fail the connection if it is not
         * there.
         */
        bool startedLinePending = false;

        /**
         * Set with `startedLinePending`: the logger's suspension that
         * `startCommand` would have held across its own wait for the
         * `started` line. The caller keeps it until it has read that
         * line (or failed to), so that the progress bar does not draw
         * over what ssh prints while connecting, and drops it then.
         * Destroying the connection drops it too.
         */
        std::unique_ptr<Logger::Suspension> loggerSuspension;

        /**
         * Try to set the buffer size in both directions to the
         * designated amount, if possible. If not possible, does
         * nothing.
         *
         * Current implementation is to use `fcntl` with `F_SETPIPE_SZ`,
         * which is Linux-only. For this implementation, `size` must
         * convertible to an `int`. In other words, it must be within
         * `[0, INT_MAX]`.
         */
        void trySetBufferSize(size_t size);
    };

    /**
     * @param command The command (arg vector) to execute.
     *
     * @param extraSshArgs Extra arguments to pass to SSH (not the command to
     * execute). Will not be used when "fake SSHing" to the local
     * machine.
     *
     * @param awaitStarted Whether to block until ssh reports the
     * connection established. A caller that must not block its thread
     * (one running inside a coroutine) passes `false` and reads the
     * line itself; see `Connection::startedLinePending`.
     */
    std::unique_ptr<Connection>
    startCommand(OsStrings && command, OsStrings && extraSshArgs = {}, bool awaitStarted = true);
};

} // namespace nix

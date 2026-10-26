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
     * Pass `-oBatchMode=yes`, so that ssh fails instead of prompting.
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
     * @param batchMode Make ssh fail instead of prompting. Needed when the
     * worker drives the connection from a coroutine, where a prompt would
     * block the worker's thread and every other goal. The build hook could
     * not prompt either, as it ran ssh under `setsid`.
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
         * Set when `startCommand` did not wait for ssh's `started` line. The
         * caller must then read it from `out` first, and fail if it is missing.
         */
        bool startedLinePending = false;

        /**
         * The logger suspension `startCommand` would have held while waiting
         * for the `started` line. The caller drops it once it has read the
         * line, so that the progress bar does not draw over ssh's output.
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
     * @param awaitStarted Whether to block until ssh prints `started`. A
     * caller in a coroutine passes `false` and reads the line itself; see
     * `Connection::startedLinePending`.
     */
    std::unique_ptr<Connection>
    startCommand(OsStrings && command, OsStrings && extraSshArgs = {}, bool awaitStarted = true);
};

} // namespace nix

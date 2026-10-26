#pragma once
///@file

#include "nix/store/common-ssh-store-config.hh"
#include "nix/store/store-api.hh"
#include "nix/store/local-fs-store.hh"
#include "nix/store/remote-store.hh"
#include "nix/util/serialise-async.hh"

namespace nix {

struct SSHStoreConfig : std::enable_shared_from_this<SSHStoreConfig>,
                        virtual RemoteStoreConfig,
                        virtual CommonSSHStoreConfig
{
private:
    void anchor() override;

public:
    SSHStoreConfig(const Params & params)
        : StoreConfig(params, FilePathType::Unix)
        , RemoteStoreConfig(params, FilePathType::Unix)
        , CommonSSHStoreConfig(params)
    {
    }

    SSHStoreConfig(const ParsedURL::Authority & authority, const Params & params);

    Setting<Strings> remoteProgram{
        this, {"nix-daemon"}, "remote-program", "Path to the `nix-daemon` executable on the remote machine."};

    static const std::string name()
    {
        return "Experimental SSH Store";
    }

    static StringSet uriSchemes()
    {
        return {"ssh-ng"};
    }

    static std::string doc();

    ref<Store> openStore() const override;

    /**
     * Open the store for use from inside the stackful coroutine that
     * `yield` belongs to, and only from there. Its connection reads and
     * writes through `AsyncFdSource`/`AsyncFdSink` on `ctx`: an
     * operation that would block suspends the coroutine, and `ctx`
     * resumes it when the descriptor is ready. The rest of
     * `RemoteStore` is unchanged; it simply finds that its synchronous
     * `Source`/`Sink` calls no longer block the thread.
     *
     * The in-process remote builder (`DerivationBuildingGoal::buildRemotely`)
     * opens the machines it builds on this way.
     */
    ref<Store> openStoreAsync(asio::io_context & ctx, asio::yield_context yield) const;

    StoreReference getReference() const override;
};

struct MountedSSHStoreConfig : virtual SSHStoreConfig, virtual LocalFSStoreConfig
{
private:
    void anchor() override;

public:
    MountedSSHStoreConfig(StringMap params);
    MountedSSHStoreConfig(const ParsedURL::Authority & authority, StringMap params);

    static const std::string name()
    {
        return "Experimental SSH Store with filesystem mounted";
    }

    static StringSet uriSchemes()
    {
        return {"mounted-ssh-ng"};
    }

    static std::string doc();

    static std::optional<ExperimentalFeature> experimentalFeature()
    {
        return ExperimentalFeature::MountedSSHStore;
    }

    ref<Store> openStore() const override;
};

} // namespace nix

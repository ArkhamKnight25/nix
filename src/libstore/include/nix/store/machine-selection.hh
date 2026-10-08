#pragma once
///@file

#include <filesystem>
#include <variant>

#include "nix/store/machines.hh"
#include "nix/store/pathlocks.hh"

namespace nix {

class Store;

/**
 * The directory holding the slot locks that record how many builds are
 * running on each machine: `<state-dir>/current-load`.
 */
std::filesystem::path getCurrentLoadDir(Store & store);

/**
 * A machine with one of its build slots reserved. The reservation lasts
 * as long as `slotLock` is held.
 */
struct AcquiredMachine
{
    /**
     * Borrowed from the `machines` argument of `acquireMachineSlot`.
     */
    Machine * machine;
    AutoCloseFD slotLock;
};

enum class NoMachine {
    /**
     * No machine supports this system and feature set, so waiting would
     * not help.
     */
    WrongType,
    /**
     * A machine of the right type exists, but every one of its slots is
     * taken. Waiting may help.
     */
    AllBusy,
};

/**
 * Reserve a build slot on the least loaded machine that can run this
 * build, under a lock on `currentLoadDir/main-lock`. The result points
 * into `machines`.
 */
std::variant<AcquiredMachine, NoMachine> acquireMachineSlot(
    const std::filesystem::path & currentLoadDir,
    Machines & machines,
    const std::string & neededSystem,
    const StringSet & requiredFeatures);

/**
 * Open the lock that serialises uploads to `storeUri`, so that
 * concurrent builds do not each copy the same closure to it.
 */
AutoCloseFD openUploadLock(const std::filesystem::path & currentLoadDir, std::string_view storeUri);

} // namespace nix

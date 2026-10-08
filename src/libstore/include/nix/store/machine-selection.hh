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
 * Replace `/` with `_` so that a store URI can be used as a single path
 * component of a lock file name.
 */
std::string escapeUri(std::string uri);

/**
 * Whether `machine` could run a build for `neededSystem` with
 * `requiredFeatures` at all, ignoring how busy it currently is.
 */
bool machineIsCandidate(const Machine & machine, const std::string & neededSystem, const StringSet & requiredFeatures);

/**
 * Whether `cand`, currently running `candLoad` builds, is a better
 * choice than `best`, currently running `bestLoad` builds.
 *
 * Load is weighted by speed factor, so a fast machine is preferred
 * while it is proportionally less loaded; on a tie the faster machine
 * wins.
 */
bool machineIsBetter(const Machine & cand, uint64_t candLoad, const Machine & best, uint64_t bestLoad);

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

/**
 * Why `acquireMachineSlot` came back empty-handed.
 */
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
 * build.
 *
 * The scan is serialised against other Nix processes by a lock on
 * `main-lock` in `currentLoadDir`, which the caller creates.
 *
 * @param machines is not `const` because `AcquiredMachine::machine`
 * points into it, and callers clear `Machine::enabled` through it when
 * they fail to connect.
 */
std::variant<AcquiredMachine, NoMachine> acquireMachineSlot(
    const std::filesystem::path & currentLoadDir,
    Machines & machines,
    const std::string & neededSystem,
    const StringSet & requiredFeatures);

/**
 * Take the lock that serialises uploads to `storeUri`, so that
 * concurrent builds do not each copy the same closure to the same
 * machine.
 */
AutoCloseFD openUploadLock(const std::filesystem::path & currentLoadDir, std::string_view storeUri);

} // namespace nix

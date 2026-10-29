#!/usr/bin/env python3
"""Throwaway: apply one mutant to the source tree. Each mutant must match exactly once."""
import sys

DBG = "src/libstore/build/derivation-building-goal.cc"
RMB = "src/libstore/unix/build/remote-machine-build.cc"
ASYNC = "src/libutil/include/nix/util/serialise-async.hh"
SSH = "src/libstore/ssh.cc"

MUTANTS = {
    "baseline": [],
    "M1-cancel": [(DBG,
        "            if (!state->done)\n"
        "                state->cancel.emit(asio::cancellation_type::terminal);\n"
        "        }\n"
        "    } cancelOnExit{state};",
        "        }\n"
        "    } cancelOnExit{state};")],
    "M2-resend": [(ASYNC,
        "data.remove_prefix(consumed);",
        "data.remove_suffix(consumed);")],
    "M3-lockheld": [(RMB,
        "localStore->locksHeld.lock()->erase(printed);",
        "(void) printed;")],
    "M4-slot-early": [(RMB,
        "    uploadLock.close();\n",
        "    uploadLock.close();\n    acquired.slotLock.close();\n")],
    "M6-loglimit": [(DBG,
        "if (logLimitExceeded && (type == resBuildLogLine || type == resSetPhase))",
        "if (false && logLimitExceeded && (type == resBuildLogLine || type == resSetPhase))")],
    "M7-failover": [(RMB,
        "acquired.machine->enabled = false;",
        "(void) 0;")],
    "M8-timesbuilt": [(DBG,
        "std::holds_alternative<RemoteMachineUnavailable>(*state->outcome)))\n"
        "        buildResult.timesBuilt++;",
        "std::holds_alternative<RemoteMachineUnavailable>(*state->outcome)))\n"
        "        (void) 0;")],
    "M9-inproc-off": [(RMB,
        "bool machineRunsInProcess(const Machine & machine)\n{\n",
        "bool machineRunsInProcess(const Machine & machine)\n{\n    if (true)\n        return false;\n")],
    "M12-cancel-late": [(RMB,
        "yield.throw_if_cancelled(true);",
        "yield.throw_if_cancelled(false);")],
    "C2-rename": [(DBG,
        "        machineName = state->machine;",
        "        (void) 0;")],
    "M13-sigterm": [(SSH,
        "        conn->sshPid.setKillSignal(SIGTERM);\n"
        "        conn->sshPid.setKillTimeout(std::chrono::seconds(10));\n",
        "")],
}

name = sys.argv[1]
for path, old, new in MUTANTS[name]:
    src = open(path, encoding="utf-8", newline="").read()
    n = src.count(old)
    if n != 1:
        sys.exit(f"MUTANT {name}: pattern found {n} times in {path}, expected 1")
    open(path, "w", encoding="utf-8", newline="").write(src.replace(old, new))
    print(f"MUTANT {name}: applied to {path}")
if not MUTANTS[name]:
    print("MUTANT baseline: no change")

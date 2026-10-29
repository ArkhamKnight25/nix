test@{
  config,
  lib,
  hostPkgs,
  ...
}:

let
  pkgs = config.nodes.client.nixpkgs.pkgs;

  builderNames = [
    "builder1"
    "builder2"
    "builder3"
  ];

  # Builds that take long enough to overlap, and record when they ran.
  # Where they ran is told by which builder holds the output afterwards
  # (the sandbox's hostname is `localhost` everywhere). `marker-<name>`
  # ends up in the builder's argv, so a builder can be found with pgrep
  # while it runs.
  expr =
    config:
    pkgs.writeText "cluster.nix" ''
      { name, seconds, count ? 1 }:
      let
        utils = builtins.storePath ${config.system.build.extraUtils};
        drv = n: derivation {
          name = "''${name}-''${toString n}";
          system = "i686-linux";
          PATH = "''${utils}/bin";
          builder = "''${utils}/bin/sh";
          args = [ "-c" (builtins.concatStringsSep "; " [
            "mkdir $out"
            "date +%s > $out/start"
            "echo marker-''${name}"
            "sleep ''${seconds}"
            "date +%s > $out/end"
          ]) ];
          outputs = [ "out" ];
        };
      in
      if count == 1 then drv 1 else builtins.genList (n: drv (n + 1)) count
    '';
in

{
  config = {
    name = lib.mkDefault "remote-builds-ssh-ng-cluster";

    nodes =
      lib.genAttrs builderNames (
        _:
        { config, pkgs, ... }:
        {
          services.openssh.enable = true;
          virtualisation.writableStore = true;
          nix.settings.sandbox = true;
          nix.settings.substituters = lib.mkForce [ ];
        }
      )
      // {
        client =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            nix.settings.max-jobs = 0; # force remote building
            nix.distributedBuilds = true;
            nix.buildMachines = map (hostName: {
              inherit hostName;
              sshUser = "root";
              sshKey = "/root/.ssh/id_ed25519";
              system = "i686-linux";
              maxJobs = 2;
              protocol = "ssh-ng";
            }) builderNames;
            virtualisation.writableStore = true;
            virtualisation.additionalPaths = [ config.system.build.extraUtils ];
            nix.settings.substituters = lib.mkForce [ ];
            # A crashed builder answers nothing; ssh must notice, not wait
            # for a TCP timeout.
            programs.ssh.extraConfig = ''
              ConnectTimeout 10
              ServerAliveInterval 5
              ServerAliveCountMax 3
            '';
            # Throwaway diagnostics.
            environment.systemPackages = [ pkgs.gdb ];
          };
      };

    testScript =
      { nodes }:
      ''
        # fmt: off
        import subprocess
        import time

        builders = [${lib.concatStringsSep ", " builderNames}]
        expr = "${expr nodes.client}"

        start_all()

        subprocess.run([
          "${hostPkgs.openssh}/bin/ssh-keygen", "-t", "ed25519", "-f", "key", "-N", ""
        ], capture_output=True, check=True)
        client.succeed("mkdir -p -m 700 /root/.ssh")
        client.copy_from_host("key", "/root/.ssh/id_ed25519")
        client.succeed("chmod 600 /root/.ssh/id_ed25519")
        client.wait_for_unit("network-addresses-eth1.service")

        for b in builders:
            b.succeed("mkdir -p -m 700 /root/.ssh")
            b.copy_from_host("key.pub", "/root/.ssh/authorized_keys")
            b.wait_for_unit("sshd")
            b.wait_for_unit("multi-user.target")
            b.wait_for_unit("network-addresses-eth1.service")
            client.succeed(f"ssh -o StrictHostKeyChecking=no {b.name} 'echo hello world'")

        # `marker-[x]yz` matches the builder's argv but not the `sh -c`
        # that runs this very pgrep, whose command line holds the pattern.
        def self_proof(s):
            return s[:-1] + "[" + s[-1] + "]"

        def who_runs(marker):
            return [b for b in builders if b.execute(f"pgrep -f '{self_proof(marker)}' > /dev/null")[0] == 0]

        def built_on(out, candidates):
            holders = [b for b in candidates if b.execute(f"test -e {out}")[0] == 0]
            assert len(holders) == 1, f"{out} is on {[b.name for b in holders]}"
            return holders[0].name

        def wait_until(pred, seconds, what):
            for _ in range(seconds * 2):
                if pred():
                    return
                time.sleep(0.5)
            # Say what the client saw before giving up.
            for f in ["interrupt.log", "crash.log", "crash.exit"]:
                print(f"--- {f}:", client.execute(f"tail -n 20 {f}")[1])
            raise Exception(f"timed out waiting for {what}")

        # Six builds at once, on three machines with two slots each. They
        # must spread over more than one machine, run concurrently, and
        # never exceed a machine's slots.
        t0 = time.monotonic()
        outs = client.succeed(
            f"nix-build {expr} --no-out-link -vvv --argstr name many --argstr seconds 20 --arg count 6 2> many.log"
        ).split()
        elapsed = time.monotonic() - t0
        assert len(outs) == 6, outs
        runs = []
        for out in outs:
            host = built_on(out, builders)
            start = int(client.succeed(f"cat {out}/start"))
            end = int(client.succeed(f"cat {out}/end"))
            runs.append((host, start, end))
        print("runs:", runs, "elapsed:", elapsed)
        hosts = {host for host, _, _ in runs}
        assert len(hosts) >= 2, f"all six builds ran on {hosts}"
        assert elapsed < 80, f"six 20-second builds took {elapsed} seconds: they did not overlap"
        for host in hosts:
            for _, s, _ in runs:
                busy = sum(1 for h, s2, e2 in runs if h == host and s2 <= s < e2)
                assert busy <= 2, f"{host} ran {busy} builds at once"
        # Every build went in-process to an ssh-ng machine (the URI carries
        # the user: ssh-ng://root@builderN); no hook process.
        print(client.succeed("grep -E \"building '|remote build done|starting build hook\" many.log | head -n 20"))
        assert int(client.succeed("grep -c \"on 'ssh-ng://root@builder\" many.log")) >= 6
        client.fail("grep -q 'starting build hook' many.log")

        # Interrupting the client stops the remote build on whichever
        # machine runs it.
        client.execute(
            f"nix-build {expr} --no-out-link --argstr name interrupt --argstr seconds 300 > interrupt.log 2>&1 &"
        )
        wait_until(lambda: who_runs("marker-interrupt"), 60, "the interrupt build to start on a builder")
        running_on = who_runs("marker-interrupt")
        print("interrupt build runs on", [b.name for b in running_on])
        client.succeed("pkill -INT -f 'name [i]nterrupt'")
        wait_until(lambda: not who_runs("marker-interrupt"), 30, "the interrupted build to stop on the builders")
        wait_until(lambda: client.execute("pgrep -f 'name [i]nterrupt'")[0] != 0, 30, "the interrupted client to exit")

        # A machine that dies while building fails that build promptly,
        # and the other machines keep working.
        # Throwaway diagnostics: what the client is doing, every second.
        client.execute(
            "(while sleep 1; do echo \"$(date +%T) lines=$(wc -l < crash.log 2> /dev/null) nix-build=$(pgrep -x nix-build | tr '\\n' ' ') nix-daemon=$(pgrep -x nix-daemon | tr '\\n' ' ') ssh=$(pgrep -x ssh | tr '\\n' ' ')\"; done > sampler.log 2>&1 &) > /dev/null 2>&1"
        )

        def dump_client():
            print("=== DIAG ps")
            print(client.execute("ps -eo pid,ppid,stat,etime,wchan:32,args --forest | grep -vE ' \\[|ps -eo|grep -vE'")[1])
            pids = client.execute("pgrep -x 'nix-build|nix-daemon|ssh' | tr '\\n' ' '")[1].split()
            for pid in pids:
                print(f"=== DIAG pid {pid}:", client.execute(f"tr '\\0' ' ' < /proc/{pid}/cmdline")[1])
                print(client.execute(f"for t in /proc/{pid}/task/*; do echo \"--- task $t $(cat $t/comm) wchan=$(cat $t/wchan)\"; cat $t/stack; done")[1])
                print(client.execute(f"ls -l /proc/{pid}/fd")[1])
                print(client.execute(f"gdb -p {pid} -batch -nx -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' 2>&1 | grep -vE '^.New LWP|^warning: (Unable|could not|Target and debugger)' | head -n 300")[1])
            print("=== DIAG sampler.log")
            print(client.execute("cat sampler.log")[1])
            print("=== DIAG crash.log")
            print(client.execute("cat -n crash.log | tail -n 300")[1])
            print("=== DIAG journal")
            print(client.execute("journalctl -b --no-pager -o short-precise | tail -n 60")[1])

        client.execute(
            f"(nix-build {expr} --no-out-link -vvvv --argstr name crash --argstr seconds 300 > crash.log 2>&1; echo $? > crash.exit) > /dev/null 2>&1 &"
        )
        wait_until(lambda: who_runs("marker-crash"), 60, "the crash build to start on a builder")
        victim = who_runs("marker-crash")[0]
        print("crash build runs on", victim.name)
        print("DIAG crashing at", client.succeed("date +%T").strip())
        victim.crash()
        crashed_at = time.monotonic()
        try:
            wait_until(lambda: client.execute("test -e crash.exit")[0] == 0, 120, "the client to notice the dead machine")
        except Exception:
            dump_client()
            raise
        print("DIAG client exited", time.monotonic() - crashed_at, "s after the crash")
        print("=== DIAG sampler.log")
        print(client.execute("cat sampler.log")[1])
        status = client.succeed("cat crash.exit").strip()
        assert status != "0", "the build on the dead machine was reported as successful"
        print(client.succeed("sed -e 's/^/crash-log:/' crash.log"))

        survivors = [b for b in builders if b is not victim]
        out = client.succeed(
            f"nix-build {expr} --no-out-link --argstr name after --argstr seconds 1 2> after.log"
        ).strip()
        host = built_on(out, survivors)
        print("build after the crash ran on", host)
      '';
  };
}

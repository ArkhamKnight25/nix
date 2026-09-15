#!/usr/bin/env bash

# Nix's side of the `build-hook` protocol: the words a hook may answer a
# probe with, and the log lines it may interleave with them. Nix's own
# hook is covered by the `build-remote*` tests; this covers what a
# third-party hook is allowed to say.

source common.sh

# `build-hook` is honoured by whichever process runs the build loop, and
# a client may not set it on the daemon.
needLocalStore "the build hook runs in the process that owns the build loop"

hook="$TEST_ROOT/hook.sh"
runs="$TEST_ROOT/hook-runs"
log="$TEST_ROOT/hook-log"

# Write a hook from stdin. It answers the probe and exits; it never reads
# its own stdin, because the parent writes the request whether or not
# anyone is reading, and each case below makes at most one request per
# hook process.
writeHook() {
    cat > "$hook"
    chmod +x "$hook"
    rm -f "$runs"
}

buildWithHook() {
    nix-build build-hook-protocol.nix --no-out-link --build-hook "$hook" "$@"
}

# "# decline" hands the build back to the local builder.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo run >> "$runs"
echo "# decline" >&2
EOF
out=$(buildWithHook -A a)
[[ $(cat "$out") = a ]]
[[ $(wc -l < "$runs") = 1 ]]

# "# decline-permanently" does the same, and is not asked again. Two
# derivations, one hook process.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo run >> "$runs"
echo "# decline-permanently" >&2
EOF
buildWithHook -A a -A b
[[ $(wc -l < "$runs") = 1 ]]

# "# postpone" makes Nix wait and ask again rather than build locally. The
# hook has to stay alive to be asked a second time.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo run >> "$runs"
echo "# postpone" >&2
echo "# decline" >&2
sleep 30
EOF
before=$SECONDS
buildWithHook -A a --build-poll-interval 2
(( SECONDS - before >= 2 ))
[[ $(wc -l < "$runs") = 1 ]]

# A line that is not a reply is passed through to the user.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo "a plain line from the hook" >&2
echo "# decline" >&2
EOF
buildWithHook -A a 2> "$log"
grepQuiet "a plain line from the hook" "$log"

# So is a JSON log message.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo '@nix {"action":"msg","level":0,"msg":"a JSON line from the hook"}' >&2
echo "# decline" >&2
EOF
buildWithHook -A a 2> "$log"
grepQuiet "a JSON line from the hook" "$log"
grepQuietInverse '@nix' "$log"

# Anything else is an error, naming the offending word.
clearStore
writeHook <<EOF
#!/usr/bin/env bash
echo "# yes please" >&2
EOF
expectStderr 1 buildWithHook -A a > "$log"
grepQuiet "bad hook reply 'yes please'" "$log"

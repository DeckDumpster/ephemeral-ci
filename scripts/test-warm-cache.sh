#!/usr/bin/env bash
# covers: scripts/warm-cache.sh, warm/consumers.json
#
# Offline: git, curl and sudo are stubs. Proves the refresh trigger moves when a lockfile
# moves, the bake runs the declared steps in order under the declared env, and a failing
# step fails the bake (a half-warm image must not look warm).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARM="${SCRIPT_DIR}/warm-cache.sh"
REAL_MANIFEST="${SCRIPT_DIR}/../warm/consumers.json"
pass=0; fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/net"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
f="$NET/$(printf '%s' "$url" | tr '/:' '__')"
[ -f "$f" ] && cat "$f" || exit 22
STUB
cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = clone ]; then mkdir -p "${@: -1}"; exit 0; fi
if [ "$1" = -C ]; then echo deadbeef; exit 0; fi
exit 1
STUB
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = install ] && { mkdir -p "${@: -1}"; exit 0; }
exec "$@"
STUB
chmod +x "$T"/bin/*

cat > "$T/m.json" <<EOF2
{"dir":"$T/warm","consumers":[{"name":"c1","repo":"https://github.com/o/c1.git","ref":"main",
 "lockfiles":["Cargo.lock"],"env":{"TARGET":"\$HOME/t"},
 "steps":["echo one:\$TARGET >> $T/log","echo two >> $T/log"]}]}
EOF2
export NET="$T/net" PATH="$T/bin:$PATH" HOME="$T/home"
mkdir -p "$HOME"
lockf="$NET/https___raw.githubusercontent.com_o_c1_main_Cargo.lock"

bash "$WARM" --manifest "$T/m.json" lock-sha >/dev/null 2>&1 && ko "lock-sha must fail when a lockfile is unfetchable" || ok "lock-sha fails when a lockfile is unfetchable"
printf 'v1\n' > "$lockf"
a="$(bash "$WARM" --manifest "$T/m.json" lock-sha)" && [ -n "$a" ] && ok "lock-sha computes" || ko "lock-sha computes"
b="$(bash "$WARM" --manifest "$T/m.json" lock-sha)"
[ "$a" = "$b" ] && ok "lock-sha is stable" || ko "lock-sha is stable"
printf 'v2\n' > "$lockf"
c="$(bash "$WARM" --manifest "$T/m.json" lock-sha)"
[ "$a" != "$c" ] && ok "lock-sha moves when a lockfile changes" || ko "lock-sha moves when a lockfile changes"

bash "$WARM" --manifest "$T/m.json" bake >"$T/bake.out" 2>&1 && ok "bake succeeds" || ko "bake succeeds: $(tail -3 "$T/bake.out")"
[ "$(cat "$T/log")" = "$(printf 'one:%s/t\ntwo' "$HOME")" ] && ok "steps ran in order under the declared env" || ko "steps ran in order under the declared env: $(cat "$T/log" 2>&1)"
grep -q 'c1 deadbeef' "$T/warm/BAKED" && grep -q "lock-sha $c" "$T/warm/BAKED" && ok "BAKED records commit and lock-sha" || ko "BAKED records commit and lock-sha"

sed -i 's/echo two/false #/' "$T/m.json"
bash "$WARM" --manifest "$T/m.json" bake >/dev/null 2>&1 && ko "failing step must fail the bake" || ok "failing step fails the bake"

# optional steps: a failure warns, skips later optional steps, and never fails the bake.
cat > "$T/m2.json" <<EOF2
{"dir":"$T/warm2","consumers":[{"name":"c1","repo":"https://github.com/o/c1.git","ref":"main",
 "lockfiles":["Cargo.lock"],
 "steps":["echo a >> $T/log2",{"run":"false","optional":true},{"run":"echo b >> $T/log2","optional":true},"echo c >> $T/log2"]}]}
EOF2
bash "$WARM" --manifest "$T/m2.json" bake >"$T/bake2.out" 2>&1 && ok "optional step failure does not fail the bake" || ko "optional step failure does not fail the bake: $(tail -3 "$T/bake2.out")"
[ "$(cat "$T/log2")" = "$(printf 'a\nc')" ] && ok "later optional steps skipped, mandatory ones still run" || ko "optional skip semantics: $(cat "$T/log2" 2>&1)"
grep -q 'WARNING' "$T/bake2.out" && ok "optional failure is warned" || ko "optional failure is warned"
sed -i 's/"echo c/"false #/' "$T/m2.json"
bash "$WARM" --manifest "$T/m2.json" bake >/dev/null 2>&1 && ko "mandatory step after optional failure must fail" || ok "mandatory step still fails the bake"

# check-warm-fresh.sh: fresh / stale / cannot-tell, against an aws stub returning the tag.
cat > "$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
[ -n "${AWS_FAIL:-}" ] && exit 1
printf '%s\n' "${AWS_TAG:-None}"
STUB
chmod +x "$T/bin/aws"
CHK="${SCRIPT_DIR}/check-warm-fresh.sh"
# the shipped manifest cannot be fetched offline: run a copy of the check pointed at the stub manifest
want="$(bash "$WARM" --manifest "$T/m.json" lock-sha)"
sed "s#warm-cache.sh\" lock-sha#warm-cache.sh\" --manifest $T/m.json lock-sha#" "$CHK" > "$T/check-a.sh"
cp "$WARM" "$T/warm-cache.sh"
AWS_TAG="$want" bash "$T/check-a.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "check-warm-fresh: matching tag is fresh" || ko "check-warm-fresh: matching tag is fresh (rc=$rc)"
AWS_TAG=old bash "$T/check-a.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 10 ] && ok "check-warm-fresh: differing tag is stale" || ko "check-warm-fresh: differing tag is stale (rc=$rc)"
AWS_FAIL=1 bash "$T/check-a.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && ok "check-warm-fresh: aws failure is never fresh" || ko "check-warm-fresh: aws failure is never fresh (rc=$rc)"

jq -e '.consumers | length > 0 and all(.[]; (.steps | length) > 0 and (.lockfiles | length) > 0)' "$REAL_MANIFEST" >/dev/null \
    && ok "shipped manifest is well-formed" || ko "shipped manifest is well-formed"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

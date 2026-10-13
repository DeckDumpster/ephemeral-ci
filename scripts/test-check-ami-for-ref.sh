#!/usr/bin/env bash
# covers: scripts/check-ami-for-ref.sh
#
# Fixture repo whose AMI inputs hash to H. A stub aws answers describe-images
# with an AMI only when the substrate-sha filter equals H. Seen-to-fail case:
# no AMI for the hash -> refused, naming the hash. Matching AMI -> passes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-ami-for-ref.sh"
PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
R="$W/repo"; mkdir -p "$R/scripts" "$R/nix" "$W/bin"
echo sub > "$R/scripts/template-substrate.sh"; echo amib > "$R/scripts/ami-build.sh"
echo env > "$R/scripts/runner-env.sh"; echo flake > "$R/nix/flake.nix"
git -C "$R" init -q; git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@t commit -qm fixture
H="$(cat "$R/scripts/template-substrate.sh" "$R/scripts/ami-build.sh" "$R/scripts/runner-env.sh" "$R/nix/flake.nix" | sha256sum | cut -d' ' -f1)"

cat > "$W/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"substrate-sha,Values=${AMI_HASH:-none}"*) echo ami-0abc ;;
esac
exit 0
STUB
chmod +x "$W/bin/aws"

rc=0; msg="$(PATH="$W/bin:$PATH" AMI_HASH=deadbeef bash "$CHECK" HEAD "$R" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && grep -q "substrate-sha=$H" <<<"$msg"; then _pass "no AMI for hash: refused, names $H"
else _fail "expected refusal naming hash (rc=$rc): $msg"; fi

rc=0; msg="$(PATH="$W/bin:$PATH" AMI_HASH="$H" bash "$CHECK" HEAD "$R" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && grep -q ami-0abc <<<"$msg"; then _pass "matching AMI: passes"
else _fail "expected pass (rc=$rc): $msg"; fi

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]

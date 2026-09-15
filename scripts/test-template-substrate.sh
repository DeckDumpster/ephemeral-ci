#!/usr/bin/env bash
# covers: scripts/template-substrate.sh
#
# Runs entirely against a stubbed PATH: no package manager, no sysctl, no
# systemctl and no hypervisor. The installing path is never executed -- it calls
# apt-get, usermod and loginctl, which a suite must not do to the machine running
# it. What is tested is --check, plus the CONTENT of the substrate list, because
# most of this file's value is the list itself and a list has no behaviour to
# observe.
#
# EVERY MATCHER HERE READS CODE, NOT PROSE. template-substrate.sh carries long
# comments by policy and those comments NAME the mechanisms these checks look for
# ("passt is the package that provides the pasta binary"). A matcher run over the
# whole file matches the EXPLANATION as readily as the mechanism, and reports a
# script the mechanism was deleted from as green. Strip comments once, up front,
# and match that. Every assertion below was seen red against a copy with the code
# removed and the prose left intact.
#
# Run: bash scripts/test-template-substrate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE="$SCRIPT_DIR/template-substrate.sh"

CODE="$(grep -vE '^[[:space:]]*#' "$SUBSTRATE")"
# Line continuations folded, so a matcher does not miss a command whose argument
# sits on the far side of a backslash.
JOINED="$(printf '%s' "$CODE" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s: %s\n' "$1" "${2:-}"; }

has() { printf '%s' "$JOINED" | grep -qE "$1"; }

echo "test-template-substrate.sh"
echo

# --- the file is usable at all -------------------------------------------

if [ -x "$SUBSTRATE" ]; then ok "template-substrate.sh is executable"
else bad "template-substrate.sh is executable" "not found or not executable at $SUBSTRATE"; fi

if bash -n "$SUBSTRATE" 2>/dev/null; then ok "it parses"
else bad "it parses" "bash -n failed"; fi

if bash "$SUBSTRATE" --nonsense >/dev/null 2>&1; then
    bad "an unknown argument is refused" "exited 0 on --nonsense"
else
    ok "an unknown argument is refused"
fi

echo
echo "the substrate list carries what a runner cannot come up without:"

# BOTH BACKENDS. podman 4.x defaults to slirp4netns, 5.x defaults to pasta and does
# NOT fall back -- it aborts with "could not find pasta, the network namespace
# can't be configured". Pinning one makes the image depend on which podman major
# the release happens to ship.
#
# MATCHED INSIDE THE ARRAY DECLARATION, not anywhere in the file. Matching the
# whole script passed a copy with slirp4netns deleted from PODMAN_PKGS, because
# `command -v slirp4netns` in the backend probe still mentioned it -- the name
# survived in a place that installs nothing.
PKG_ARRAYS="$(printf '%s' "$JOINED" | grep -E '^[A-Z_]+_PKGS=\(')"
for pkg in podman uidmap fuse-overlayfs slirp4netns passt catatonit; do
    if printf '%s' "$PKG_ARRAYS" | grep -qE "(\(|[[:space:]])${pkg}([[:space:]]|\))"; then
        ok "the list names $pkg"
    else
        bad "the list names $pkg" "absent from the *_PKGS arrays"
    fi
done

# Rust links through cc, and so do native Python wheels; the failure reads as a
# broken language toolchain rather than a missing Debian package.
if printf '%s' "$PKG_ARRAYS" | grep -qE '(\(|[[:space:]])build-essential([[:space:]]|\))'; then
    ok "the list names build-essential"
else
    bad "the list names build-essential" "cargo fails with 'linker cc not found', which reads as a Rust problem"
fi

echo
echo "the machine properties that fail silently are asserted:"

# A backend must be asserted to EXIST rather than inferred from podman's version,
# which says nothing about which backend is installed.
if has 'command -v pasta' && has 'command -v slirp4netns'; then
    ok "a network backend is asserted to exist, not inferred from the version"
else
    bad "a network backend is asserted to exist, not inferred from the version" "no command -v probe for either backend"
fi

if has 'apparmor_restrict_unprivileged_userns'; then
    ok "the AppArmor userns restriction is checked"
else
    bad "the AppArmor userns restriction is checked" "rootless bridge networks fail with an EPERM naming neither AppArmor nor pasta"
fi

# The live sysctl does not survive the reboot between building a template and
# cloning it, so it must also be written to a file.
if has 'sysctl.d/'; then
    ok "the sysctl is persisted to a file, not only set live"
else
    bad "the sysctl is persisted to a file, not only set live" "a live-only sysctl is lost when the template is cloned"
fi

# The UNIT must be acted on, not merely mentioned. Matching the bare name passed a
# copy that only named it in a log line, which disables nothing.
# MASKED, not merely disabled: a disabled unit can be pulled back in as another
# unit's dependency. TEMPLATE.md has said so since e02f95b.
if has 'systemctl mask[^|]*unattended-upgrades'; then
    ok "unattended-upgrades is masked, not just disabled"
else
    bad "unattended-upgrades is masked, not just disabled" "disable alone is undone by any unit that depends on it"
fi

if has 'DPkg::Lock::Timeout=[0-9]+'; then
    ok "apt waits for the dpkg lock"
else
    bad "apt waits for the dpkg lock" "the boot-time upgrade race is lost roughly one run in several"
fi

if has 'loginctl' && has 'Linger'; then
    ok "lingering is checked"
else
    bad "lingering is checked" "without it /run/user/<uid> is never created and rootless podman has nowhere to keep state"
fi

if has '/etc/subuid' && has '/etc/subgid'; then
    ok "subuid/subgid are checked"
else
    bad "subuid/subgid are checked" "rootless podman cannot map users without them"
fi

echo
echo "the failure modes that cost a run are handled, not just the happy path:"

# apt installs a list as ONE transaction, so a single name with no installation
# candidate aborts every other package with it.
# shellcheck disable=SC2016  # these are regexes matching a literal $, not expansions
if has 'for [A-Za-z_]+ in "\$\{want\[@\]\}"' && has 'apt-get install .*"\$p"'; then
    ok "one uninstallable name does not take the list with it"
else
    bad "one uninstallable name does not take the list with it" "no per-package retry after a failed batch"
fi

# `apt-cache show` succeeds for a t64-renamed package that has no installation
# candidate; asking for the candidate is the question actually being asked.
if has 'apt-cache policy'; then
    ok "installability is asked of apt-cache policy, not apt-cache show"
else
    bad "installability is asked of apt-cache policy, not apt-cache show" "24.04's t64 renames leave uninstallable records that apt-cache show reports as present"
fi

if has 't64'; then
    ok "the t64 rename is handled"
else
    bad "the t64 rename is handled" "libfoo is installed as libfoot64 on 24.04 and reads as missing forever"
fi

# A partial apply must fail here rather than surface inside a consumer's job on a
# VM that has already been destroyed.
if has 'still missing after apply'; then
    ok "a partial apply is a failure, not a surprise later"
else
    bad "a partial apply is a failure, not a surprise later" "the installer does not re-check its own work"
fi

echo
echo "--check is safe and says what it found:"

# THE WHOLE POINT OF --check IS THAT IT TOUCHES NOTHING. Verified by running it
# with a PATH where every mutating tool is a stub that fails loudly if called.
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT
CALLS="$STUBS/calls"

# THE LEDGER PATH IS BAKED IN AT WRITE TIME, not referenced as a variable. Written
# as '$STUBS/calls' inside single quotes it would be expanded when the STUB runs,
# where STUBS is unset because nothing exported it -- so every stub would append to
# /calls, fail on permissions, and the ledger would never exist. `[ ! -s ]` on a
# file that cannot be created is TRUE, so "mutates nothing" would have passed no
# matter what the script did. shellcheck (SC2016) is what caught it.
# ALWAYS-MUTATING TOOLS: any call at all is a violation in check mode.
_mkstub() {
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit %s\n' \
        "$1" "$CALLS" "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}
for t in apt-get usermod tee; do _mkstub "$t" 0; done

# SOMETIMES-MUTATING TOOLS. loginctl, systemctl and sysctl are how the script
# READS three machine properties, so their mere use is not a violation and an
# earlier version of this check failed on `sysctl -n` and `systemctl
# list-unit-files`. What must never happen in check mode is the mutating
# subcommand, so these stubs record only those. Exit 1 so the read path is
# exercised as "property absent" rather than short-circuited.
_mkstub_rw() {
    cat > "$STUBS/$1" <<STUB
#!/bin/sh
case " \$* " in
    *" enable-linger "*|*" disable "*|*" enable "*|*" -w "*|*" --now "*)
        printf '%s %s\n' "$1" "\$*" >> "$CALLS" ;;
esac
exit 1
STUB
    chmod +x "$STUBS/$1"
}
for t in loginctl systemctl sysctl; do _mkstub_rw "$t"; done

# POSITIVE CONTROL FIRST: prove the ledger can record before believing it is empty.
# An unwritable or misnamed ledger is indistinguishable from a clean run, and that
# is exactly the bug this block had.
"$STUBS/apt-get" --positive-control >/dev/null 2>&1
"$STUBS/systemctl" disable --now something >/dev/null 2>&1
_pc_lines=$(wc -l < "$CALLS" 2>/dev/null || echo 0)
if [ "${_pc_lines:-0}" -ge 2 ]; then
    ok "the stub ledger records both stub kinds (positive control)"
else
    bad "the stub ledger records both stub kinds (positive control)" "recorded ${_pc_lines:-0} of 2; an unwritable ledger is indistinguishable from a clean run"
fi
# ...and that a READ through the same stub is NOT recorded, or the check below
# would fail on the script merely looking at a property.
"$STUBS/systemctl" list-unit-files foo >/dev/null 2>&1
if [ "$(wc -l < "$CALLS")" -eq "$_pc_lines" ]; then
    ok "a read-only call is not counted as a mutation"
else
    bad "a read-only call is not counted as a mutation" "list-unit-files was recorded; the check would fail on correct code"
fi
: > "$CALLS"

PATH="$STUBS:$PATH" bash "$SUBSTRATE" --check >/dev/null 2>&1
_rc=$?
if [ ! -s "$CALLS" ]; then
    ok "--check mutates nothing"
else
    bad "--check mutates nothing" "called: $(tr '\n' ';' < "$CALLS")"
fi

# On a machine with nothing configured it must exit non-zero -- a check that
# cannot fail is not a check.
if [ "$_rc" -ne 0 ]; then
    ok "--check exits non-zero when the substrate is absent"
else
    bad "--check exits non-zero when the substrate is absent" "exited 0 against a stubbed-empty machine"
fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

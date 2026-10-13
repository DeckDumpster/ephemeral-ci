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
for pkg in uidmap fuse3; do
    if printf '%s' "$PKG_ARRAYS" | grep -qE "(\(|[[:space:]])${pkg}([[:space:]]|\))"; then
        ok "the list names $pkg"
    else
        bad "the list names $pkg" "absent from the *_PKGS arrays"
    fi
done

# The engine is the pinned nix env, not apt: its flake names every helper, the substrate
# asserts the env is built and first on PATH, and installs it through runner-env.sh.
for pkg in podman crun conmon netavark aardvark-dns slirp4netns passt fuse-overlayfs catatonit git; do
    if grep -qE "^[[:space:]]+(podmanPkgs\.)?${pkg}([[:space:]]|$)" "$SCRIPT_DIR/../nix/flake.nix"; then ok "the runner-env flake names $pkg"
    else bad "the runner-env flake names $pkg" "absent from nix/flake.nix"; fi
done
if has '^[[:space:]]*check_runner_env$' && has 'bash "\$RUNNER_ENV_SH" install'; then ok "the substrate builds and checks the pinned runner env"
else bad "the substrate builds and checks the pinned runner env" "no check_runner_env / runner-env.sh install"; fi

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

# All three apt automation units are masked. unattended-upgrades.service does the
# upgrades; apt-daily-upgrade.timer schedules them; apt-daily.timer schedules the
# preceding apt-get update. Masking only the service leaves the timers running
# and able to race provisioning for the dpkg lock.
# MASKED, not merely disabled: a disabled unit can be pulled back in as another
# unit's dependency. TEMPLATE.md has said so since e02f95b.
if has 'systemctl mask'; then
    ok "apt automation units are masked, not just disabled"
else
    bad "apt automation units are masked, not just disabled" "disable alone is undone by any unit that depends on it"
fi

for _au in 'unattended-upgrades.service' 'apt-daily.timer' 'apt-daily-upgrade.timer'; do
    if has "$_au"; then
        ok "the mask/check path names $_au"
    else
        bad "the mask/check path names $_au" "this unit drives apt automation and can race provisioning for the dpkg lock"
    fi
done

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
echo "the declared runner memory size is asserted:"

# RUNNER_MEM_MIB=6144 must appear in the code, not just in comments. The test
# for the boundary: if the constant is only in a comment, `has` matches the
# comment text and the check below still passes while the actual guard is absent.
if has 'RUNNER_MEM_MIB=6144'; then
    ok "RUNNER_MEM_MIB=6144 is declared"
else
    bad "RUNNER_MEM_MIB=6144 is declared" "the declared allocation is the single source of truth for the range check"
fi

# The check must read the actual RAM from /proc/meminfo, not infer it from the
# template VMID or from anything set at provision time.
if has 'MemTotal'; then
    ok "MemTotal is read from /proc/meminfo to verify the allocation"
else
    bad "MemTotal is read from /proc/meminfo to verify the allocation" "the check cannot enforce the declared size without reading the actual RAM"
fi

# The check must test BOTH bounds (under-provisioned and over-provisioned).
# A one-sided check misses the case this bead was filed for: a template
# inherited from a hand-built 12288 MiB VM that nobody ever measured.
# shellcheck disable=SC2016  # the single quotes are the point: this greps for the literal text
if has '\$memtotal_mib.*-lt.*\$lo' && has '\$memtotal_mib.*-gt.*\$hi'; then
    ok "both bounds are checked (under- and over-provisioned)"
else
    bad "both bounds are checked (under- and over-provisioned)" "a one-sided check misses template drift in either direction"
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
# Silent stub: dpkg always exits 1 (package not installed). Not recorded in
# $CALLS because dpkg -s is read-only; recording it would break the
# "--check mutates nothing" assertion. Without this, apt_install short-circuits
# on a host where all packages are already installed and apt-get is never reached.
printf '#!/bin/sh\nexit 1\n' > "$STUBS/dpkg"; chmod +x "$STUBS/dpkg"

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

# --- the apply path must actually apply when it is root ------------------
#
# THE DOCUMENTED INVOCATION IS `sudo bash template-substrate.sh`, and under it
# id -u is 0 and $SUDO is empty -- empty because $SUDO is a command PREFIX, not
# a permission flag. The install path tested `[ -n "$SUDO" ]` and so refused
# the only caller holding full privilege, printing "need root to install" and
# installing nothing. It applied the non-package work regardless, so it looked
# like a script that ran and partly failed rather than one that could never
# install anything at all.
#
# Root is simulated with an `id` stub rather than by running the suite as root,
# which a suite must not require. The assertion is that apt-get is REACHED --
# the stub records the call and exits 0 -- not that any package is really
# installed.
_idstub() {
    cat > "$STUBS/id" <<'STUB'
#!/bin/sh
case " $* " in *" -u "*) echo 0; exit 0 ;; esac
exec /usr/bin/id "$@"
STUB
    chmod +x "$STUBS/id"
}
_idstub
: > "$CALLS"
_apply_out="$(PATH="$STUBS:$PATH" bash "$SUBSTRATE" 2>&1)"
if grep -q '^apt-get ' "$CALLS"; then
    ok "the apply path reaches apt-get when running as root"
else
    bad "the apply path reaches apt-get when running as root" \
        "apt-get was never called; script said: $(printf '%s' "$_apply_out" | grep -i 'root\|elevate' | head -1)"
fi
if printf '%s' "$_apply_out" | grep -qi 'need root to install'; then
    bad "the apply path does not claim it needs root while running as root" \
        "printed 'need root to install' with id -u = 0"
else
    ok "the apply path does not claim it needs root while running as root"
fi
rm -f "$STUBS/id"
: > "$CALLS"

echo
echo "apt_install runs apt-get update before probing installability:"

# Proof: apt-cache policy returns a candidate only after a marker file written
# by apt-get update. On the old ordering (probe before update) the marker is
# absent when installable() runs, no candidate is seen, and apt-get install is
# never called. On the correct ordering (update before probe) the marker exists
# and packages are selected. That test fails on the old code and passes after.
_TSTUBS="$(mktemp -d)"
_TMARKER="$_TSTUBS/apt-updated"
_TCALLS="$_TSTUBS/apt-calls"

cat > "$_TSTUBS/apt-cache" <<STUB
#!/bin/sh
case "\$1" in
    policy)
        if [ -f "$_TMARKER" ]; then
            printf '  Installed: (none)\n  Candidate: 1.0\n'
        fi
        exit 0 ;;
    *) exec /usr/bin/apt-cache "\$@" ;;
esac
STUB
chmod +x "$_TSTUBS/apt-cache"

cat > "$_TSTUBS/apt-get" <<STUB
#!/bin/sh
printf 'apt-get %s\n' "\$1" >> "$_TCALLS"
case "\$1" in update) touch "$_TMARKER" ;; esac
exit 0
STUB
chmod +x "$_TSTUBS/apt-get"

printf '#!/bin/sh\nexit 1\n' > "$_TSTUBS/dpkg"; chmod +x "$_TSTUBS/dpkg"

cat > "$_TSTUBS/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
STUB
chmod +x "$_TSTUBS/id"

for _t in systemctl loginctl usermod sysctl; do
    printf '#!/bin/sh\nexit 0\n' > "$_TSTUBS/$_t"; chmod +x "$_TSTUBS/$_t"
done

PATH="$_TSTUBS:$PATH" bash "$SUBSTRATE" >/dev/null 2>&1 || true

if grep -q '^apt-get install' "$_TCALLS" 2>/dev/null; then
    ok "apt-get install is called (update ran before probe; packages selected)"
else
    bad "apt-get install is called (update ran before probe; packages selected)" \
        "install was never reached; probe likely ran before update and saw no candidates"
fi
rm -rf "$_TSTUBS"

echo
echo "memory check: SUBSTRATE_MEM_DECLARED controls one-sided vs two-sided window:"

# MEMINFO_FILE lets the test inject a specific MemTotal without root or mocking awk.
# SUBSTRATE_MEM_DECLARED=1 (the default) applies both bounds; =0 applies the floor only.
_mc_dir="$(mktemp -d)"
_check_mem() {
    local mib="$1" expect="$2" desc="$3" declared="${4-unset}"
    local minfo="$_mc_dir/meminfo"
    printf 'MemTotal:       %d kB\n' $(( mib * 1024 )) > "$minfo"
    local out
    # SUBSTRATE_USER: use the running user so the check is not short-circuited
    # by a missing 'runner' user on the test machine, and reaches the memory check.
    if [ "$declared" = "unset" ]; then
        out="$(env -u SUBSTRATE_MEM_DECLARED SUBSTRATE_USER="$(id -un)" MEMINFO_FILE="$minfo" bash "$SUBSTRATE" --check 2>&1)" || true
    else
        out="$(SUBSTRATE_MEM_DECLARED="$declared" SUBSTRATE_USER="$(id -un)" MEMINFO_FILE="$minfo" bash "$SUBSTRATE" --check 2>&1)" || true
    fi
    if [ "$expect" = pass ]; then
        if printf '%s' "$out" | grep -q 'MISSING mem~'; then
            bad "$desc" "$(printf '%s' "$out" | grep 'MISSING mem~' | head -1)"
        else
            ok "$desc"
        fi
    else
        if printf '%s' "$out" | grep -q 'MISSING mem~'; then
            ok "$desc"
        else
            bad "$desc" "memory check should have failed at ${mib}MiB but passed"
        fi
    fi
}

# declared=1: both bounds enforced
_check_mem 6144 pass "declared=1: 6144MiB passes (within ±20% window)" 1
_check_mem 7775 fail "declared=1: 7775MiB fails (ceiling enforced; this was the regression)" 1
_check_mem 3812 fail "declared=1: 3812MiB fails (below floor)" 1

echo
echo "memory check: declared=0 (cloud/EC2) is one-sided (floor only):"

# declared=0: only the floor matters; instances with more RAM than the declared size pass.
_check_mem 7775 pass "declared=0: 7775MiB passes (no ceiling on cloud)" 0
_check_mem 3812 fail "declared=0: 3812MiB fails (below floor)" 0

echo
echo "memory check: unset SUBSTRATE_MEM_DECLARED defaults to strict (declared=1):"

# The default must be the STRICTER check: a missing signal produces a visible false
# failure rather than a silently absent assertion.
_check_mem 7775 fail "unset SUBSTRATE_MEM_DECLARED: 7775MiB fails (defaults to strict)" unset
rm -rf "$_mc_dir"

echo
echo "apt-get update failure: substrate fails naming the apt error:"

_upd_dir="$(mktemp -d)"
_upd_calls="$_upd_dir/calls"

cat > "$_upd_dir/apt-get" <<STUB
#!/bin/sh
printf 'apt-get %s\n' "\$1" >> "$_upd_calls"
case "\$1" in
    update) printf 'E: stub: could not resolve apt.ubuntu.com\n' >&2; exit 100 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$_upd_dir/apt-get"

cat > "$_upd_dir/apt-cache" <<'STUB'
#!/bin/sh
printf '  Installed: (none)\n  Candidate: (none)\n'
exit 0
STUB
chmod +x "$_upd_dir/apt-cache"

printf '#!/bin/sh\nexit 1\n' > "$_upd_dir/dpkg"; chmod +x "$_upd_dir/dpkg"

cat > "$_upd_dir/id" <<'STUB'
#!/bin/sh
case " $* " in *" -u "*) echo 0; exit 0 ;; esac
exec /usr/bin/id "$@"
STUB
chmod +x "$_upd_dir/id"

# sleep: make the retry loop instantaneous in tests.
printf '#!/bin/sh\nexit 0\n' > "$_upd_dir/sleep"; chmod +x "$_upd_dir/sleep"

for _t in systemctl loginctl usermod sysctl tee; do
    printf '#!/bin/sh\nexit 0\n' > "$_upd_dir/$_t"; chmod +x "$_upd_dir/$_t"
done

_upd_rc=0
_upd_out="$(PATH="$_upd_dir:$PATH" bash "$SUBSTRATE" 2>&1)" || _upd_rc=$?

if [ "$_upd_rc" -ne 0 ]; then
    ok "apt-update failure: substrate exits non-zero"
else
    bad "apt-update failure: substrate exits non-zero" "exited 0 after apt-get update failed"
fi

if printf '%s' "$_upd_out" | grep -q 'apt-get update failed'; then
    ok "apt-update failure: output names the apt-get update failure"
else
    bad "apt-update failure: output names the apt-get update failure" \
        "got: $(printf '%s' "$_upd_out" | grep -v '^substrate:' | head -3)"
fi

if ! printf '%s' "$_upd_out" | grep -q 'not on this release'; then
    ok "apt-update failure: does not mislead with missing-package message"
else
    bad "apt-update failure: does not mislead with missing-package message" \
        "printed 'not on this release' after apt-get update failed"
fi

rm -rf "$_upd_dir"

echo
echo "absent user: substrate fails immediately naming the missing user:"

_absent_dir="$(mktemp -d)"

# Stub id to fail when asked about absent-test-user; otherwise report root (id -u → 0).
cat > "$_absent_dir/id" <<'STUB'
#!/bin/sh
for a; do [ "$a" = "absent-test-user" ] && { printf 'id: absent-test-user: no such user\n' >&2; exit 1; }; done
case " $* " in *" -u "*) echo 0; exit 0 ;; esac
exec /usr/bin/id "$@"
STUB
chmod +x "$_absent_dir/id"

_absent_rc=0
_absent_out="$(SUBSTRATE_USER=absent-test-user PATH="$_absent_dir:$PATH" bash "$SUBSTRATE" 2>&1)" || _absent_rc=$?

if [ "$_absent_rc" -ne 0 ]; then
    ok "absent user: substrate exits non-zero"
else
    bad "absent user: substrate exits non-zero" "exited 0 when SUBSTRATE_USER=absent-test-user but that user does not exist"
fi

if printf '%s' "$_absent_out" | grep -q 'absent-test-user'; then
    ok "absent user: error names the missing user"
else
    bad "absent user: error names the missing user" "got: $(printf '%s' "$_absent_out" | head -3)"
fi

rm -rf "$_absent_dir"

echo
echo "runner images are general purpose; the runner may install its repository's deps:"

# No repository's packages in the shared substrate (sp-kfadex reverses sp-4tmf61).
for pkg in libnss3 libatk1.0-0 libgbm1 libgl1 libasound2 libpango-1.0-0 chromium fonts-liberation; do
    if printf '%s' "$PKG_ARRAYS" | grep -qE "(\(|[[:space:]])${pkg}([[:space:]]|\))"; then
        bad "the list does not name $pkg" "repo-specific package in the shared substrate"
    else
        ok "the list does not name $pkg"
    fi
done
if printf '%s' "$PKG_ARRAYS" | grep -q '^UI_PKGS='; then
    bad "no UI_PKGS array" "UI_PKGS is back"
else
    ok "no UI_PKGS array"
fi

# Absence over the whole code, not only the arrays: no installer line may name them.
for pkg in libnss3 libatk1.0-0 libgbm1 libgl1 fonts-liberation; do
    if has "(^|[^A-Za-z0-9.+-])${pkg}([^A-Za-z0-9.+-]|\$)"; then bad "substrate code never names $pkg" "found in code"
    else ok "substrate code never names $pkg"; fi
done

# Doc lint: TEMPLATE.md must not tell a human to bake a repository's packages.
# Wrapped lines and backslash continuations are folded first: the phrase and the
# package list both wrap in the prose that this lint exists to catch.
_doc="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$SCRIPT_DIR/../docs/TEMPLATE.md" | tr '\n' ' ' | tr -s ' ')"
if printf '%s' "$_doc" | grep -qi 'before baking the template' && printf '%s' "$_doc" | grep -qE 'apt(-get)? install.*(libnss3|libatk|libgbm|libgl1|fonts-liberation)'; then
    bad "TEMPLATE.md does not instruct baking repo packages" "found 'before baking the template' with an apt install of a repo package"
else ok "TEMPLATE.md does not instruct baking repo packages"; fi
if printf '%s' "$_doc" | grep -qE 'apt(-get)? install.*(libnss3|libatk1\.0-0|libgbm1|libgl1)'; then
    bad "TEMPLATE.md has no apt install of Chromium libs" "found"
else ok "TEMPLATE.md has no apt install of Chromium libs"; fi

# Exact drop-in content, taken by running the function itself.
_sd_fn="$(sed -n '/^sudoers_content()/,/^}/p' "$SUBSTRATE")"
_sd_got="$(RUNUSER=runner bash -c "$_sd_fn; sudoers_content")"
_sd_want='runner ALL=(ALL) NOPASSWD: ALL'
if [ "$_sd_got" = "$_sd_want" ]; then ok "sudoers drop-in content is exactly full NOPASSWD sudo"
else bad "sudoers drop-in content is exactly full NOPASSWD sudo" "got: $_sd_got"; fi
if has 'install -m 0440 .*"\$SUDOERS_FILE"' && has 'visudo -cf'; then ok "the drop-in is installed 0440 after visudo validation"
else bad "the drop-in is installed 0440 after visudo validation" "install or visudo step missing"; fi
if has '^[[:space:]]*check_sudoers$'; then ok "--check verifies the drop-in"
else bad "--check verifies the drop-in" "check_sudoers not in run_checks"; fi

# The apt proxy is OPTIONAL and FAILS OPEN: the drop-in is a Proxy-Auto-Detect hook,
# not a static Proxy; the hook prints the URL when the cache answers and DIRECT when not.
_ap_fn="$(sed -n '/^apt_proxy_content()/,/^}/p' "$SUBSTRATE")"
_ap_got="$(APT_PROXY_DETECT=/usr/local/bin/x bash -c "$_ap_fn; apt_proxy_content")"
if [ "$_ap_got" = 'Acquire::http::Proxy-Auto-Detect "/usr/local/bin/x";' ]; then ok "apt proxy drop-in is a Proxy-Auto-Detect line"
else bad "apt proxy drop-in is a Proxy-Auto-Detect line" "got: $_ap_got"; fi
if printf '%s' "$CODE" | grep -qE '^Acquire::http::Proxy "'; then bad "no static Acquire::http::Proxy anywhere" "found one"
else ok "no static Acquire::http::Proxy anywhere"; fi
if has '^[[:space:]]*check_apt_proxy$'; then ok "--check verifies the apt proxy"
else bad "--check verifies the apt proxy" "check_apt_proxy not in run_checks"; fi
_ap_w="$(printf '%s\n' "$CODE" | grep -n 'tee "\$APT_PROXY_FILE"' | head -1 | cut -d: -f1)"
_ap_u="$(printf '%s\n' "$CODE" | grep -n 'apt_install "\${PODMAN_PKGS' | head -1 | cut -d: -f1)"
if [ -n "$_ap_w" ] && [ -n "$_ap_u" ] && [ "$_ap_w" -lt "$_ap_u" ]; then ok "the proxy is written before the first apt-get update"
else bad "the proxy is written before the first apt-get update" "write at ${_ap_w:-none}, install at ${_ap_u:-none}"; fi
if has 'exit 1 ;;' && ! has 'SUBSTRATE_APT_PROXY is not set'; then ok "install does not refuse an unset SUBSTRATE_APT_PROXY"
else bad "install does not refuse an unset SUBSTRATE_APT_PROXY" "refusal still present"; fi
if grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/ami-build.sh" | grep -q "SUBSTRATE_APT_PROXY='\${APT_PROXY_URL:-}'"; then ok "ami-build.sh passes an optional SUBSTRATE_APT_PROXY to the substrate"
else bad "ami-build.sh passes an optional SUBSTRATE_APT_PROXY to the substrate" "not passed with a :- default"; fi
if grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/ami-build.sh" | grep -q 'APT_PROXY_URL is not set'; then bad "ami-build.sh runs with APT_PROXY_URL unset" "still refuses"
else ok "ami-build.sh runs with APT_PROXY_URL unset"; fi

# The detect hook itself, extracted from the substrate and run against real sockets.
_dt="$(mktemp -d)"
bash -c "$(sed -n '/^apt_proxy_detect_content()/,/^}/p' "$SUBSTRATE"); apt_proxy_detect_content" > "$_dt/detect.sh"
_dt_port="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
printf 'http://127.0.0.1:%s\n' "$_dt_port" > "$_dt/url"
_dt_closed="$(APT_PROXY_CACHE_FILE="$_dt/url" bash "$_dt/detect.sh" example.com)"
if [ "$_dt_closed" = DIRECT ]; then ok "detect prints DIRECT when the cache port is closed"
else bad "detect prints DIRECT when the cache port is closed" "got: $_dt_closed"; fi
python3 -I -c 'import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",'"$_dt_port"'));s.listen(5);time.sleep(15)' &
_dt_pid=$!
sleep 1
_dt_open="$(APT_PROXY_CACHE_FILE="$_dt/url" bash "$_dt/detect.sh" example.com)"
kill "$_dt_pid" 2>/dev/null; wait "$_dt_pid" 2>/dev/null
if [ "$_dt_open" = "http://127.0.0.1:$_dt_port" ]; then ok "detect prints the URL when the cache port is open"
else bad "detect prints the URL when the cache port is open" "got: $_dt_open"; fi
_dt_none="$(APT_PROXY_CACHE_FILE="$_dt/absent" bash "$_dt/detect.sh" example.com)"
if [ "$_dt_none" = DIRECT ]; then ok "detect prints DIRECT with no URL file"
else bad "detect prints DIRECT with no URL file" "got: $_dt_none"; fi
printf 'garbage; rm -rf\n' > "$_dt/bad"
if [ "$(APT_PROXY_CACHE_FILE="$_dt/bad" bash "$_dt/detect.sh" x)" = DIRECT ]; then ok "detect prints DIRECT for an unparseable URL"
else bad "detect prints DIRECT for an unparseable URL" "not DIRECT"; fi
printf 'http://10.255.255.1:3142\n' > "$_dt/blackhole"
_dt_t0=$SECONDS
APT_PROXY_CACHE_FILE="$_dt/blackhole" bash "$_dt/detect.sh" x >/dev/null
if [ $((SECONDS - _dt_t0)) -le 3 ]; then ok "detect answers within ~1 s for an unroutable cache"
else bad "detect answers within ~1 s for an unroutable cache" "took $((SECONDS - _dt_t0))s"; fi
rm -rf "$_dt"

# --check with the variable unset passes the proxy item.
if env -u SUBSTRATE_APT_PROXY APT_PROXY_FILE=/nonexistent bash -c "$(sed -n '/^check_apt_proxy()/,/^}/p' "$SUBSTRATE"); check_apt_proxy"; then ok "check_apt_proxy passes when no proxy was requested"
else bad "check_apt_proxy passes when no proxy was requested" "reported missing"; fi

# Both images are built by this one script: the Proxmox template (provision.sh)
# and the spill AMI (ami-build.sh), so the drop-in is identical on both.
for f in provision.sh ami-build.sh; do
    code_refs="$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/$f" | grep -c 'template-substrate.sh' || true)"
    if [ "$code_refs" -gt 0 ]; then ok "$f builds through template-substrate.sh"
    else bad "$f builds through template-substrate.sh" "does not reference it in code"; fi
done

# The spill AMI's runner must give rootless podman the same user-manager and
# runtime dir the Proxmox template's does (sp-oauh2n).
_ab="$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/ami-build.sh")"
if printf '%s\n' "$_ab" | grep -q 'useradd --system'; then bad "the spill runner is a regular user" "useradd --system gives no user manager"
else ok "the spill runner is a regular user"; fi
if printf '%s\n' "$_ab" | grep -q '^Environment=XDG_RUNTIME_DIR=/run/user/%U'; then bad "the spill runner service takes its uid from session.env" "%U in a system unit expands to 0"
elif printf '%s\n' "$_ab" | grep -q '^EnvironmentFile=/etc/ephemeral-runner/session.env' && printf '%s\n' "$_ab" | grep -q 'XDG_RUNTIME_DIR=/run/user/%s'; then ok "the spill runner service takes its uid from session.env"
else bad "the spill runner service takes its uid from session.env" "no EnvironmentFile with the real uid"; fi
# sp-2lzkvo: podman must be found on the unit's own PATH, and on the user manager's.
if printf '%s\n' "$_ab" | grep -q -- 'EnvironmentFile=/etc/ephemeral-runner/session.env /usr/bin/env '; then ok "the build-time podman check resolves podman on the runner unit's PATH"
else bad "the build-time podman check resolves podman on the runner unit's PATH" "systemd-run resolves a bare podman on sudo's PATH"; fi
if printf '%s\n' "$_ab" | grep -q '^PATH=.*50-runner-env.conf\|environment.d/50-runner-env.conf' && printf '%s\n' "$_ab" | grep -q 'runner-env/bin'; then ok "the user manager's environment carries the runner-env bin"
else bad "the user manager's environment carries the runner-env bin" "no environment.d entry"; fi
if printf '%s\n' "$_ab" | grep -q '^Wants=user@\\\${RUNNER_UID}.service' && printf '%s\n' "$_ab" | grep -q '^After=.*user@\\\${RUNNER_UID}.service'; then ok "the spill runner service waits for the user manager"
else bad "the spill runner service waits for the user manager" "no Wants/After user@<uid>.service"; fi
if printf '%s\n' "$_ab" | grep -q 'podman info fails under the runner service'; then ok "the AMI build proves podman info passes for the runner before imaging"
else bad "the AMI build proves podman info passes for the runner before imaging" "no check"; fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

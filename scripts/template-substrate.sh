#!/usr/bin/env bash
# covers: docs/TEMPLATE.md (the "Packages and tooling" and "Container store" sections)
#
# The machine properties every ephemeral runner needs, as a script rather than a
# paragraph.
#
#   bash scripts/template-substrate.sh            install/apply anything missing
#   bash scripts/template-substrate.sh --check    report what is missing; exit 1 if any
#
# RUN THIS WHEN BUILDING THE TEMPLATE, BEFORE CONVERTING THE VM. It is idempotent,
# so it is also safe at the head of a job to verify a clone came up correctly --
# though a --check failure there means the template is wrong, not the job.
#
# WHY THIS EXISTS. docs/TEMPLATE.md carried this list as prose with bash blocks a
# human pasted. Nothing executed it and nothing checked it, so the list drifted
# from what the runners actually needed and every consuming repository rediscovered
# the gap separately, one CI round-trip at a time. In a single afternoon two repos
# independently hit the same missing pasta, the same uid-pinning bug and the same
# boot-time dpkg race; a third had already solved two of them months earlier in a
# file nothing else could see. A dependency a human has to remember is a dependency
# that is missing on the next machine.
#
# WHAT BELONGS HERE, AND WHAT DOES NOT. This file is the SUBSTRATE: properties of
# the machine that every consumer needs and no consumer should have to know about.
# A dependency of one repository's suite -- uv, Chromium's shared libraries, a Rust
# toolchain, metric-compatible fonts for visual regression -- belongs in that
# repository's own runner-deps check, which declares what IS its own. The test for
# the boundary: if a second repository would be surprised to need it, it is not
# substrate.
set -uo pipefail

MODE=install
case "${1:-}" in
    --check) MODE=check ;;
    "")      MODE=install ;;
    *)       printf 'usage: template-substrate.sh [--check]\n' >&2; exit 2 ;;
esac

MISSING=()
note() { printf 'substrate: %s\n' "$*" >&2; }
lack() { MISSING+=("$1"); printf 'substrate: MISSING %s -- %s\n' "$1" "$2" >&2; }

# BOTH STREAMS ARE stderr. Progress on stdout and gaps on stderr interleave
# unpredictably once a CI log merges them, and a run has already printed
# "rootless ok" AFTER "this machine cannot run the suites", which reads as a
# contradiction and sends the reader to the wrong half of the script.

# SUDO IS A PREFIX, NOT A PERMISSION FLAG, AND CONFLATING THE TWO MADE THIS
# SCRIPT INERT.
#
# $SUDO is deliberately EMPTY when the caller is already root -- that is what
# lets every mutating call below read `$SUDO apt-get ...` and work in both
# cases. The install path then tested `[ -n "$SUDO" ]` as if it meant "I have
# privilege", so the one caller with FULL privilege was the only one refused.
# docs/TEMPLATE.md documents exactly that caller:
#
#     sudo bash scripts/template-substrate.sh
#
# Under sudo, id -u is 0, $SUDO is empty, and the script printed "need root to
# install" and returned 1 -- while still applying the non-package work, so it
# reported progress, changed some things, and failed about the rest. No package
# has ever been installed through the documented invocation. Template 9110 has
# no podman at all, and CI only survives that because each consuming workflow
# installs a container runtime per job.
#
# CAN_ELEVATE answers the question the install path is actually asking.
SUDO=""
CAN_ELEVATE=0
if [ "$(id -u)" -eq 0 ]; then
    CAN_ELEVATE=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
    CAN_ELEVATE=1
fi

RUNUSER="${SUBSTRATE_USER:-runner}"
id -u "$RUNUSER" >/dev/null 2>&1 || RUNUSER="$(id -un)"

# ---------------------------------------------------------------------------
# apt, with the two failure modes a per-run VM actually hits
# ---------------------------------------------------------------------------

# WAIT FOR THE DPKG LOCK RATHER THAN FAILING ON IT. The VM boots, systemd starts
# unattended-upgrades, and provisioning starts installing -- in that order, seconds
# apart. Whoever reaches /var/lib/dpkg/lock-frontend second gets "Could not get
# lock ... held by process N (unattended-upgr)" and, with no timeout, gives up at
# once. It is a RACE, so it fails perhaps one run in several with a list that
# installed cleanly on the runs either side: it reads as a broken dependency list
# rather than a timing bug, and the first thing anyone does is re-run, which works.
#
# Unquoted on purpose below: it must expand to two words, or to nothing on an apt
# too old to know the option (added in apt 1.9.11).
#
# This is the belt. The braces is disable_unattended_upgrades() further down, which
# is the durable fix: a VM that lives thirty minutes and is then destroyed has
# nothing to gain from an unattended upgrade. Both, because the template may be
# rebuilt by someone who skips this script.
APT_LOCK_WAIT="-o DPkg::Lock::Timeout=600"

# installable <pkg> -- true when apt can actually install this name.
#
# `apt-cache show` is NOT this test and using it cost a CI run. Ubuntu 24.04's
# 64-bit time_t transition renamed a dozen library packages with a `t64` suffix and
# left the OLD name in the cache as a record with no installation candidate, so
# `apt-cache show libasound2` succeeds while `apt-get install libasound2` fails with
# "has no installation candidate". Ask for the candidate version, which is the
# question actually being asked.
installable() {
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^  Candidate: //p')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

APT_UPDATED=0
apt_install() {
    local want=() p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 && continue
        dpkg -s "${p}t64" >/dev/null 2>&1 && continue
        if installable "$p"; then
            want+=("$p")
        elif installable "${p}t64"; then
            want+=("${p}t64")
        else
            note "no installable package named $p or ${p}t64 on this release -- skipping"
        fi
    done
    [ ${#want[@]} -gt 0 ] || return 0
    [ "$CAN_ELEVATE" -eq 1 ] || { note "cannot elevate to install: ${want[*]}"; return 1; }
    if [ "$APT_UPDATED" = 0 ]; then
        # shellcheck disable=SC2086
        $SUDO apt-get update -qq $APT_LOCK_WAIT
        APT_UPDATED=1
    fi
    note "installing ${want[*]}"
    # shellcheck disable=SC2086
    if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq $APT_LOCK_WAIT "${want[@]}"; then
        return 0
    fi
    # ONE BAD NAME MUST NOT COST THE OTHERS. apt installs a list as a single
    # transaction, so a package with no installation candidate on this release
    # aborts every other package alongside it. This cannot rescue a lock failure --
    # the retry would race the same holder -- which is what APT_LOCK_WAIT is for.
    note "batch install failed -- retrying one at a time"
    for p in "${want[@]}"; do
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq $APT_LOCK_WAIT "$p" \
            || note "could not install $p"
    done
}

# ---------------------------------------------------------------------------
# Rootless podman, and the two things that break it silently
# ---------------------------------------------------------------------------
#
# uidmap          newuidmap/newgidmap; without it `podman run` fails with
#                 "newuidmap not found".
# fuse-overlayfs  rootless overlay storage. Without it podman falls back to vfs,
#                 where a ~983 MB builder stage takes minutes instead of seconds.
# catatonit       the init podman uses for --init; absent, that flag fails late.
# slirp4netns
# passt           BOTH network backends, deliberately. podman 4.x defaults to
#                 slirp4netns and 5.x defaults to pasta, and 5.x does NOT fall
#                 back -- it aborts with "could not find pasta, the network
#                 namespace can't be configured", or, on a user-defined bridge,
#                 with "rootless netns: kill network process: permission denied",
#                 which names neither pasta nor a package. passt is the package
#                 that provides the pasta binary. Installing both costs a few
#                 hundred kilobytes and makes the image independent of which
#                 podman major the release ships.
PODMAN_PKGS=(podman uidmap fuse-overlayfs slirp4netns passt catatonit)

# A C COMPILER IS A MACHINE PROPERTY, NOT A LANGUAGE DEPENDENCY. Rust shells out to
# `cc` to link and fails with "linker `cc` not found", which reads as a broken Rust
# toolchain; native Python wheels and cgo do the same. It was on the old shared box
# because somebody put it there and no file recorded it.
BUILD_PKGS=(build-essential pkg-config)

# The runner itself and the scripts every consumer's CI calls directly.
BASE_PKGS=(git curl ca-certificates jq awscli)

check_podman() {
    command -v podman >/dev/null 2>&1 || { lack podman "every consumer runs containers"; return 1; }
    local v major minor
    v="$(podman --version 2>/dev/null | awk '{print $3}')"
    major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
    case "${major:-x}${minor:-x}" in
        *[!0-9]*) note "cannot parse podman version [$v] -- not enforcing the floor" ;;
        *)
            # Not a missing binary -- a silently wrong one. Quadlet .container
            # support arrived in 4.4; older podman IGNORES .container files, so
            # `systemctl --user start <unit>` succeeds having started nothing and
            # every later `podman port` returns empty.
            if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 4 ]; }; then
                lack "podman>=4.4" "found $v; Quadlet .container files are ignored below 4.4 and CI fails far downstream with an empty port"
                return 1
            fi
            ;;
    esac
    note "container engine $v"
}

# ASSERT A BACKEND EXISTS RATHER THAN INFERRING ONE FROM THE VERSION. podman's
# version says nothing about which backend was compiled in or installed; either
# binary satisfies this.
check_netns_backend() {
    command -v pasta >/dev/null 2>&1 && return 0
    command -v slirp4netns >/dev/null 2>&1 && return 0
    lack "pasta or slirp4netns" "rootless podman has no network backend; it aborts with 'could not find pasta'"
    return 1
}

check_pkgs() {
    local p missing=()
    command -v dpkg >/dev/null 2>&1 || return 0
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 && continue
        dpkg -s "${p}t64" >/dev/null 2>&1 && continue
        missing+=("$p")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    lack "packages (${missing[*]})" "named in the substrate list"
    return 1
}

check_subid() {
    grep -q "^${RUNUSER}:" /etc/subuid 2>/dev/null \
        && grep -q "^${RUNUSER}:" /etc/subgid 2>/dev/null && return 0
    lack "subuid/subgid for ${RUNUSER}" "rootless podman cannot map users without them"
    return 1
}

# LINGERING, BECAUSE THE RUNNER IS A SERVICE AND NOT A LOGIN SESSION. Without it
# /run/user/<uid> is never created, so rootless podman has nowhere to keep its
# state and `systemctl --user` has no user manager to talk to. The failure names
# neither lingering nor the runtime directory.
check_linger() {
    command -v loginctl >/dev/null 2>&1 || return 0
    [ "$(loginctl show-user "$RUNUSER" -p Linger --value 2>/dev/null)" = "yes" ] && return 0
    lack "linger for ${RUNUSER}" "/run/user/<uid> is never created; rootless podman and systemctl --user both fail obscurely"
    return 1
}

# UNPRIVILEGED USER NAMESPACES MUST NOT BE APPARMOR-RESTRICTED. Ubuntu 24.04 turned
# on kernel.apparmor_restrict_unprivileged_userns, which drops a process creating an
# unprivileged userns into a restricted AppArmor domain. podman starts pasta inside
# the rootless network namespace that user-defined (bridge) networks require; pasta
# lands in that domain and podman, in a different one, can no longer signal it:
#
#   Error: rootless netns: cleanup: 1 error occurred:
#     * rootless netns: kill network process: permission denied
#
# naming neither AppArmor nor a namespace, and reproducing with pasta correctly
# installed. Containers on podman's DEFAULT network are unaffected, which is why one
# repository's suite passes on the same template while another's does not -- the gap
# is invisible until a consumer with a different network shape arrives.
APPARMOR_SYSCTL=kernel.apparmor_restrict_unprivileged_userns
SYSCTL_FILE=/etc/sysctl.d/99-ephemeral-ci-userns.conf

check_userns() {
    local cur
    cur="$(sysctl -n "$APPARMOR_SYSCTL" 2>/dev/null)" || return 0   # kernel lacks it: fine
    [ "$cur" = "0" ] && return 0
    lack "$APPARMOR_SYSCTL=0" "currently $cur; rootless bridge networks fail with EPERM killing the network process, naming neither AppArmor nor pasta"
    return 1
}

# APT AUTOMATION HAS NOTHING TO OFFER A VM THAT LIVES THIRTY MINUTES, and it
# holds the dpkg lock at exactly the moment provisioning wants it. This is the
# durable half of the fix; APT_LOCK_WAIT above is the half that still works on a
# box where somebody has re-enabled it.
# ALL THREE UNITS. unattended-upgrades.service does the upgrades;
# apt-daily-upgrade.timer schedules them; apt-daily.timer schedules the preceding
# apt-get update. Masking only the service leaves the timers running, which can
# still race for the lock at boot.
# MASKED, NOT MERELY DISABLED. A disabled unit can be pulled back in as another
# unit's dependency; masking is what makes that impossible. Purging is finer still
# and satisfies this check by making the unit absent.
check_unattended() {
    local state u
    command -v systemctl >/dev/null 2>&1 || return 0
    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        state="$(systemctl is-enabled "$u" 2>/dev/null)"
        case "$state" in
            ''|masked|disabled|'not-found'|linked-runtime) ;;
            *)
                lack "$u masked" "it is '$state'; apt automation races provisioning for the dpkg lock at boot — one run in several fails with a dependency list that worked the run before"
                return 1
                ;;
        esac
    done
    return 0
}

# THE DECLARED RUNNER ALLOCATION. A template with a different size silently caps
# the runner fleet: every concurrent run holds its full allocation for the length
# of the run, so node_capacity / per_runner_allocation IS the fleet ceiling. Six
# consecutive full-corpus gate runs measured a cgroup high-water of ~1.5 GiB with
# ~1.7 GiB held by the OS and runner process before any suite starts, for a
# total of ~3.3 GiB. 6144 MiB provides 2x headroom and allows six concurrent
# runners on this node (vs two at 12288 MiB). See docs/TEMPLATE.md for the
# measurement table and the fleet concurrency math.
#
# The check reads MemTotal from /proc/meminfo (which is 1-5% below the allocation
# due to reserved memory) and fails outside a ±20% window: floor=4915, ceil=7372.
RUNNER_MEM_MIB=6144

check_mem_size() {
    local memtotal_mib lo hi remedy
    [ -r /proc/meminfo ] || return 0
    memtotal_mib="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    [ -n "$memtotal_mib" ] || return 0
    lo=$(( RUNNER_MEM_MIB * 4 / 5 ))
    hi=$(( RUNNER_MEM_MIB * 6 / 5 ))
    if command -v qm >/dev/null 2>&1; then
        remedy="qm set <VMID> --memory ${RUNNER_MEM_MIB}"
    else
        remedy="use an instance type with ≥${RUNNER_MEM_MIB}MiB RAM (e.g. c7i.xlarge)"
    fi
    if [ "$memtotal_mib" -lt "$lo" ] || [ "$memtotal_mib" -gt "$hi" ]; then
        lack "mem~${RUNNER_MEM_MIB}MiB" "MemTotal is ${memtotal_mib}MiB; declared ${RUNNER_MEM_MIB}MiB (±20% window ${lo}–${hi}MiB); resize with: ${remedy}"
        return 1
    fi
    note "mem ${memtotal_mib}MiB (declared ${RUNNER_MEM_MIB}MiB)"
}

# /tmp MUST NOT BE A RAM DISK. Ubuntu mounts /tmp as a tmpfs sized at half of RAM,
# so a suite with a disk floor measures 3.7G free on a VM whose root filesystem has
# 79G. It is not a disk problem with the machine and it does not look like a
# configuration one either. Reported, not changed: the fix is a template decision
# (mask tmp.mount, or size the VM's RAM for it) and silently remounting /tmp under a
# running job would be worse than the diagnosis.
check_tmp_backing() {
    local fstype
    fstype="$(findmnt -no FSTYPE --target /tmp 2>/dev/null)" || return 0
    [ "$fstype" = "tmpfs" ] || return 0
    note "NOTE /tmp is a tmpfs ($(findmnt -no SIZE --target /tmp 2>/dev/null) of RAM). A suite with a disk floor will measure that, not the root filesystem. Mask tmp.mount in the template if a consumer needs a disk-backed /tmp."
}

run_checks() {
    MISSING=()
    check_podman
    check_netns_backend
    check_pkgs "${PODMAN_PKGS[@]}" "${BUILD_PKGS[@]}" "${BASE_PKGS[@]}"
    check_subid
    check_linger
    check_userns
    check_unattended
    check_tmp_backing
    check_mem_size
}

if [ "$MODE" = check ]; then
    run_checks
    if [ ${#MISSING[@]} -gt 0 ]; then
        printf '\nsubstrate: %d item(s) missing on %s (user %s).\n' "${#MISSING[@]}" "$(hostname)" "$RUNUSER" >&2
        printf 'substrate: apply them with:  sudo bash scripts/template-substrate.sh\n' >&2
        exit 1
    fi
    note "all substrate present"
    exit 0
fi

# --------------------------------- install ---------------------------------
note "applying substrate for ${RUNUSER} on $(hostname)"

# Mask apt automation BEFORE the first apt-get update. On a freshly booted
# instance unattended-upgrades runs at the same moment provisioning does;
# it can hold the dpkg lock when apt-get update runs, causing universe
# package lists to be absent from the cache while main (already cached on
# the AMI) still resolves. The masking was previously done after apt_install,
# which was too late to prevent that race.
if command -v systemctl >/dev/null 2>&1; then
    for _apt_unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        case "$(systemctl is-enabled "$_apt_unit" 2>/dev/null)" in
            ''|masked|'not-found') ;;
            *)
                note "masking $_apt_unit (apt automation races provisioning for the dpkg lock)"
                $SUDO systemctl disable --now "$_apt_unit" \
                    || note "could not disable $_apt_unit"
                $SUDO systemctl mask "$_apt_unit" \
                    || note "could not mask $_apt_unit"
                ;;
        esac
    done
fi

apt_install "${PODMAN_PKGS[@]}" "${BUILD_PKGS[@]}" "${BASE_PKGS[@]}"

if ! grep -q "^${RUNUSER}:" /etc/subuid 2>/dev/null \
   || ! grep -q "^${RUNUSER}:" /etc/subgid 2>/dev/null; then
    note "adding subuid/subgid range for ${RUNUSER}"
    $SUDO usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$RUNUSER" \
        || note "could not add subuid/subgid range for ${RUNUSER}"
fi

if command -v loginctl >/dev/null 2>&1 \
   && [ "$(loginctl show-user "$RUNUSER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    note "enabling linger for ${RUNUSER}"
    $SUDO loginctl enable-linger "$RUNUSER" || note "could not enable lingering for ${RUNUSER}"
fi

if [ -n "$(sysctl -n "$APPARMOR_SYSCTL" 2>/dev/null)" ]; then
    # Written to a file as well as set live: the live value does not survive the
    # reboot between building a template and cloning it.
    note "setting ${APPARMOR_SYSCTL}=0 (live and in ${SYSCTL_FILE})"
    printf '%s = 0\n' "$APPARMOR_SYSCTL" | $SUDO tee "$SYSCTL_FILE" >/dev/null \
        || note "could not write ${SYSCTL_FILE}"
    $SUDO sysctl -q -w "${APPARMOR_SYSCTL}=0" || note "could not set ${APPARMOR_SYSCTL} live"
fi

# Re-check and report. A partial apply is a failure here rather than a surprise
# inside a consumer's job on a VM that no longer exists.
printf '\n'
run_checks
if [ ${#MISSING[@]} -gt 0 ]; then
    printf '\nsubstrate: still missing after apply: %s\n' "${MISSING[*]}" >&2
    exit 1
fi
note "all substrate present"

#!/bin/bash
#
# ASCII ONLY. Proxmox's agent/file-write cannot carry a non-ASCII byte: it
# fails with "Wide character in subroutine entry at .../Qemu/Agent.pm" and
# HTTP 500. One em dash in a comment here broke every provision until the API's
# error body was printed. provision.sh refuses to send this file if it contains
# one, so the failure is named at the source rather than by the hypervisor.
#
# Registers this VM as a one-shot GitHub Actions runner, takes one job, and
# powers off. Runs inside the ephemeral guest, started by ephemeral-runner.path
# when provision.sh writes /run/gh-runner-init.
#
# THIS FILE IS DELIVERED BY provision.sh ON EVERY RUN, not baked into the VM
# template. The template carries only the unpacked runner, the guest agent and
# the path unit. Changing this script therefore does not require rebuilding and
# resealing the template -- which, the one time it did, cost an evening.
#
# NO POWEROFF ON FAILURE. An unconditional `sudo poweroff` is why an earlier
# fault took a VGA framebuffer dump to diagnose: the VM erased its own evidence
# about eighteen seconds in. A failed run leaves the machine up with the reason
# in the journal; the reaper collects it later.
set -uo pipefail

INIT=/run/gh-runner-init
RUNNER_DIR=/home/runner/actions-runner

fail() { echo "start-runner: $*" >&2; exit 1; }

[ -r "$INIT" ] || fail "no injected data at $INIT"

# Belt and braces against a partially written file. provision.sh writes to a
# temp path and renames, so this path should only ever appear complete -- but
# the failure mode when it is not is a five-times-in-one-second restart loop
# that rate-limits the unit and then ignores every subsequent write, which is
# expensive to diagnose and trivial to prevent. RUNNER_GROUP is written last.
grep -q '^RUNNER_GROUP=' "$INIT" || fail "$INIT is incomplete - refusing to source a partial file"
# shellcheck disable=SC1090
. "$INIT"
: "${RUNNER_LABEL:?RUNNER_LABEL missing from $INIT}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN missing from $INIT}"
: "${RUNNER_URL:?RUNNER_URL missing from $INIT}"
: "${RUNNER_GROUP:?RUNNER_GROUP missing from $INIT}"

cd "$RUNNER_DIR" || fail "$RUNNER_DIR missing"

# The template boots with kernel.threads-max 26115 (sized from its small RAM),
# below the 32768 pids limit Spira's testenv containers ask for; testenv then
# refuses to start and the job fails after it has already been accepted. Raise
# it BEFORE registering, and refuse to register if it did not take, so a runner
# that cannot run Spira's suites never appears in the pool. The drop-in
# persists it for the VM's life; the VM is single-use.
MIN_THREADS_MAX=65536
cur=$(cat /proc/sys/kernel/threads-max 2>/dev/null || echo 0)
if [ "$cur" -lt "$MIN_THREADS_MAX" ]; then
    echo "kernel.threads-max = $MIN_THREADS_MAX" \
        | sudo -n tee /etc/sysctl.d/90-ephemeral-ci-threads.conf >/dev/null \
        || fail "cannot write /etc/sysctl.d/90-ephemeral-ci-threads.conf"
    sudo -n sysctl -w "kernel.threads-max=$MIN_THREADS_MAX" >/dev/null \
        || fail "sysctl -w kernel.threads-max=$MIN_THREADS_MAX failed"
fi
cur=$(cat /proc/sys/kernel/threads-max 2>/dev/null || echo 0)
[ "$cur" -ge "$MIN_THREADS_MAX" ] \
    || fail "kernel.threads-max is $cur, need >= $MIN_THREADS_MAX; refusing to register"

# The pinned runner env (nix/flake.nix, installed by template-substrate.sh) goes first on PATH
# for this script and, through run.sh, for every job: both images then run the same podman.
# shellcheck disable=SC1091
[ -r /etc/ephemeral-ci/runner-env.sh ] && . /etc/ephemeral-ci/runner-env.sh

# ROOTLESS PODMAN NEEDS THE RUNNER'S OWN USER SESSION. This script runs as a
# system unit (User=runner), so nothing hands it XDG_RUNTIME_DIR or a user bus;
# podman then depends on whatever it can guess, and "podman info fails" names
# neither. Set them from the real uid, make sure the user manager is up, and
# prove podman starts BEFORE registering, so a runner that cannot run a
# container never appears in the pool (law-fixed-when-a-real-test-starts). run.sh
# inherits these, so jobs see the same session.
RUNNER_UID=$(id -u)
export XDG_RUNTIME_DIR="/run/user/${RUNNER_UID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null
    sudo -n systemctl start "user@${RUNNER_UID}.service" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -d "$XDG_RUNTIME_DIR" ] && break
        sleep 1
    done
fi
[ -d "$XDG_RUNTIME_DIR" ] || fail "$XDG_RUNTIME_DIR does not exist (user manager not running); refusing to register"
# The template stays general: podman is installed by each job's own runner-deps,
# so its absence here is not a fault. A podman that IS installed must work.
if command -v podman >/dev/null 2>&1; then
    podman_err=$(podman info 2>&1 >/dev/null) \
        || fail "podman info failed as $(id -un) with XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR: $podman_err; refusing to register"
else
    echo "podman not installed on this template; runner-deps provides it, skipping the pre-register check"
fi

# RUNNER_URL is the ORGANIZATION url, because the token is an org registration
# token. --runnergroup is what then keeps that runner usable by one repository.
# Without it the runner joins the Default group, which is visible to every
# repository in the organisation -- the exact scope problem that registering
# against the org was supposed to avoid.
./config.sh --unattended --ephemeral \
    --url "$RUNNER_URL" \
    --token "$RUNNER_TOKEN" \
    --runnergroup "$RUNNER_GROUP" \
    --labels "$RUNNER_LABEL" \
    --name "$RUNNER_LABEL" \
    || fail "config.sh failed"

rm -f "$INIT"      # single-use token, already spent

./run.sh || fail "run.sh exited non-zero"

sudo poweroff

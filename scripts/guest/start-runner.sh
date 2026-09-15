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

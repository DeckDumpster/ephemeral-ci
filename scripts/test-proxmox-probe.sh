#!/usr/bin/env bash
#
# scripts/test-proxmox-probe.sh
#
# Asserts the shape of .github/workflows/proxmox-probe.yml (the Proxmox-path twin
# of the EC2 spill probe) and that guest/start-runner.sh sets the runner's
# session env and proves podman before registering. Offline; needs python3 with
# PyYAML.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WF="$REPO_DIR/.github/workflows/proxmox-probe.yml"
FAILS=0

python3 -I - <<'PY' || FAILS=1
import os, sys, yaml
wf = yaml.safe_load(open(os.environ["WF"]))
on = wf.get(True, wf.get("on"))
jobs = wf["jobs"]
bad = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond: bad.append(msg)

paths = (on.get("push") or {}).get("paths", [])
for p in ("scripts/provision.sh", "scripts/template-substrate.sh", "scripts/guest/**", "provision/**"):
    check(p in paths, "runs on a change to " + p)
check("workflow_dispatch" in on, "runnable on demand (after a template reseal)")
prov = [s for s in jobs["provision"]["steps"] if s.get("uses") == "./provision"][0]["with"]
check(prov.get("spill") == "off" and prov.get("template-vmid"), "provisions on the Proxmox template, no spill")
steps = "\n".join(s.get("name", "") + "\n" + s.get("run", "") for s in jobs["verify"]["steps"])
for needle in ("podman info", "podman run", "runner-deps (spira)", "runner-deps (pokedumpster)",
               "runner-deps (deckdumpster)", "first test starts (spira)",
               "first test starts (pokedumpster)", "first test starts (deckdumpster)"):
    check(needle in steps, "verify has " + needle)
check(jobs["teardown"].get("if", "").startswith("always()"), "teardown always runs")
check("report" in jobs, "a failed probe files a P0")
sys.exit(1 if bad else 0)
PY

S="$REPO_DIR/scripts/guest/start-runner.sh"
for needle in 'export XDG_RUNTIME_DIR="/run/user/${RUNNER_UID}"' 'podman info' 'refusing to register'; do
    grep -qF "$needle" "$S" && echo "ok   start-runner.sh: $needle" \
        || { echo "FAIL start-runner.sh lacks: $needle"; FAILS=1; }
done
# podman must be proven before the runner registers.
pl=$(grep -n 'podman info' "$S" | head -1 | cut -d: -f1); cl=$(grep -n '^./config.sh' "$S" | head -1 | cut -d: -f1)
[ -n "$pl" ] && [ -n "$cl" ] && [ "$pl" -lt "$cl" ] \
    && echo "ok   podman is proven before config.sh" || { echo "FAIL podman check must precede config.sh"; FAILS=1; }

exit "$FAILS"

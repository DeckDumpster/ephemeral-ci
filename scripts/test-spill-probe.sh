#!/usr/bin/env bash
#
# scripts/test-spill-probe.sh
#
# Asserts the shape of .github/workflows/spill-probe.yml: it fires on a
# successful "Build spill AMI", promotes only after verify passes, checks the
# launched ImageId, and exercises podman and each consumer's runner-deps.
# Offline; needs python3 with PyYAML.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WF="$REPO_DIR/.github/workflows/spill-probe.yml"
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

wr = on.get("workflow_run") or {}
check(wr.get("workflows") == ["Build spill AMI"] and wr.get("types") == ["completed"],
      "triggered by workflow_run of 'Build spill AMI' completed")
check("workflow_dispatch" in on, "still runnable on demand")
check(not ({"push", "pull_request", "schedule"} & set(on)), "no push/pull_request/schedule trigger")
check("conclusion == 'success'" in jobs["resolve"].get("if", ""),
      "only a successful AMI build is probed")

check(jobs["promote"]["needs"] == ["resolve", "verify"] or "verify" in jobs["promote"]["needs"],
      "promote waits on verify")
promote_run = "\n".join(s.get("run", "") for s in jobs["promote"]["steps"])
check("spill:probe,Value=passed" in promote_run, "promote sets spill:probe=passed")
check("if" not in jobs["promote"], "promote has no always() escape: it runs only if verify succeeded")
for j, d in jobs.items():
    if j != "promote":
        check("spill:probe,Value=passed" not in "\n".join(s.get("run", "") for s in d.get("steps", [])),
              f"{j} does not promote")

steps = "\n".join(str(s.get("run", "")) + " " + str(s.get("name", "")) for s in jobs["verify"]["steps"])
for needle, what in [("ami-id", "asserts the launched ImageId"), ("podman info", "podman info"),
                     ("podman run --rm", "podman run"), ("NetworkBackend", "network backend")]:
    check(needle in steps, "verify " + what)
for repo in ("spira", "pokedumpster", "deckdumpster"):
    check(f"runner-deps ({repo})" in steps, f"verify runs runner-deps for {repo}")
check(jobs["verify"]["timeout-minutes"] <= 15, "verify fits the 15-minute wall")
vsteps = jobs["verify"]["steps"]
names = [s.get("name", "") for s in vsteps]
for repo in ("spira", "pokedumpster", "deckdumpster"):
    n = f"first test starts ({repo})"
    check(n in names, f"verify starts {repo}'s first real test")
    if n in names:
        step = vsteps[names.index(n)]
        check("spill-probe-first-test.sh" in step["run"] and repo in step["run"],
              f"{repo}'s start is detected from its output by the marker helper")
        check(names.index(n) > names.index(f"runner-deps ({repo})"), f"{repo}'s first test follows its runner-deps")
check(max(names.index(f"first test starts ({r})") for r in ("spira", "pokedumpster", "deckdumpster")) < len(names),
      "all three starts are in verify, which promote needs")
check(jobs["provision"]["steps"][1]["with"].get("spill-ami-id"), "provision launches the AMI under test")
check("P0" in str(jobs["report"]), "failure files a P0")
sys.exit(1 if bad else 0)
PY

# provision.sh must launch only promoted AMIs unless told which AMI to probe.
grep -q 'spill:probe,Values=passed' "$REPO_DIR/scripts/provision.sh" \
    && echo "ok   provision.sh selects only probe-passed AMIs" \
    || { echo "FAIL provision.sh does not require spill:probe=passed"; FAILS=1; }

exit "$FAILS"

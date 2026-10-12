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
check(jobs["verify"]["timeout-minutes"] <= 30, "verify fits the 30-minute wall (a cold test-image build)")
vsteps = jobs["verify"]["steps"]
names = [s.get("name", "") for s in vsteps]
for repo in ("pokedumpster", "deckdumpster"):
    n = f"first test starts ({repo})"
    check(n in names, f"verify starts {repo}'s first real test")
    if n in names:
        step = vsteps[names.index(n)]
        check("spill-probe-first-test.sh" in step["run"] and repo in step["run"],
              f"{repo}'s start is detected from its output by the marker helper")
        check(names.index(n) > names.index(f"runner-deps ({repo})"), f"{repo}'s first test follows its runner-deps")
vs = {s.get("name"): s for s in vsteps}
check("first test starts (spira)" not in names,
      "spira's first-test step stays removed (it failed on the probe's own gh dependency, not the runner)")
for repo in ("pokedumpster", "deckdumpster"):
    check(vs[f"first test starts ({repo})"].get("continue-on-error") is True,
          f"{repo}'s first test does not stop the others")
check(vs.get("first test verdict", {}).get("if") == "always()", "one aggregated first-test verdict")
check(max(names.index(f"first test starts ({r})") for r in ("pokedumpster", "deckdumpster")) < len(names),
      "both starts are in verify, which promote needs")
check(jobs["provision"]["steps"][1]["with"].get("spill-ami-id"), "provision launches the AMI under test")
check("P0" in str(jobs["report"]), "failure files a P0")
vsteps = {s.get("name"): s for s in jobs["verify"]["steps"]}
for repo, path in (("spira", "spira/runner-deps.sh"), ("pokedumpster", "deploy/runner-deps.sh"),
                   ("deckdumpster", "deploy/runner-deps.sh")):
    st = vsteps.get(f"runner-deps ({repo})", {})
    check(st.get("run") == "bash " + path, f"runner-deps ({repo}) runs {path}")
    check(st.get("continue-on-error") is True, f"runner-deps ({repo}) does not stop the others")
check(vsteps.get("runner-deps verdict", {}).get("if") == "always()", "one aggregated runner-deps verdict")
sys.exit(1 if bad else 0)
PY

# provision.sh must launch only promoted AMIs unless told which AMI to probe.
grep -q 'spill:probe,Values=passed' "$REPO_DIR/scripts/provision.sh" \
    && echo "ok   provision.sh selects only probe-passed AMIs" \
    || { echo "FAIL provision.sh does not require spill:probe=passed"; FAILS=1; }

# The paths must exist in the consuming repos' own checkouts when present here.
for pair in "$HOME/pokedumpster:deploy/runner-deps.sh" "$HOME/deckdumpster:deploy/runner-deps.sh"; do
    [ -d "${pair%%:*}" ] || continue
    [ -f "${pair%%:*}/${pair#*:}" ] && echo "ok   ${pair#*:} exists in ${pair%%:*}" \
        || { echo "FAIL ${pair#*:} missing in ${pair%%:*}"; FAILS=1; }
done

# Verdict: every repo reported, any non-success fails and is named.
V="$REPO_DIR/scripts/spill-probe-verdict.sh"
out="$(bash "$V" spira=failure pokedumpster=success deckdumpster=failure 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'spira (failure)' <<<"$out" && grep -q 'deckdumpster (failure)' <<<"$out" \
    && ! grep -q 'error.*pokedumpster' <<<"$out"; } \
    && echo "ok   verdict names each failing repo" || { echo "FAIL verdict: rc=$rc $out"; FAILS=1; }
bash "$V" spira=success pokedumpster=success >/dev/null 2>&1 \
    && echo "ok   verdict passes when all pass" || { echo "FAIL verdict on all-pass"; FAILS=1; }

# Report: creates the label, and still files when the label cannot be had.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "$1 $2" = "label create" ] && [ -n "${NOLABEL:-}" ] && exit 1
[ "$1 $2" = "issue create" ] && [[ "$*" == *--label* ]] && [ -n "${NOLABEL:-}" ] && exit 1
[ "$1" = issue ] && cat >/dev/null; exit 0
SH
chmod +x "$T/gh"
R="$REPO_DIR/scripts/spill-probe-report.sh"
GH="$T/gh" GH_LOG="$T/a.log" bash "$R" ami-1 http://run "tail" >/dev/null 2>&1
{ grep -q '^label create P0' "$T/a.log" && grep -q '^issue create.*--label P0' "$T/a.log"; } \
    && echo "ok   report creates the P0 label then files with it" || { echo "FAIL report with label"; FAILS=1; }
NOLABEL=1 GH="$T/gh" GH_LOG="$T/b.log" bash "$R" ami-1 http://run "tail" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(grep -c '^issue create' "$T/b.log")" -ge 1 ] && tail -1 "$T/b.log" | grep -qv -- '--label'; } \
    && echo "ok   report files without the label when it cannot be created" || { echo "FAIL report without label rc=$rc"; FAILS=1; }

exit "$FAILS"

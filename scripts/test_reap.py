"""Tests for scripts/reap.sh (originally deckdumpster db-hqp).

Each test plants a specific offender and verifies the reaper's verdict.
A test that finds nothing must first prove it could have found something:
- tests that assert "kept" also include a second VM that IS reaped,
  confirming the reaper ran and made a decision.

Scenarios verified:
  1. Ledger line in the future → kept
  2. Ledger line past the cutoff → reaped
  3. VM with no ctime in config → kept and reported, exit 1
  4. Planted meta: line in the real Proxmox format → epoch parsed correctly
  5. Proxmox API enumeration fails → exit non-zero, not "no VMs found"
  6. GitHub busy check reports runner live → kept regardless of age
  7. VMs not named gh-runner-* (Agent-Swarm, Prod-Services) → never selected

All API calls (Proxmox + GitHub) are handled by a stub curl script on PATH.
No hypervisor or network required.
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

REAP_SH = Path(__file__).resolve().parent / "reap.sh"

# Stub curl that routes requests based on environment variables.
# URL routing uses regex matching; STUB_FAIL_URL is a regex pattern applied
# to the full URL — a match causes curl to exit 6 (connection failure).
#
# Variables consumed:
#   STUB_VM_LIST          JSON for GET /nodes/{node}/qemu
#   STUB_VM_{N}_CONFIG    JSON for GET /nodes/{node}/qemu/{N}/config
#   STUB_VM_{N}_STATUS    JSON for GET /nodes/{node}/qemu/{N}/status/current
#   STUB_RUNNERS          JSON for GET https://api.github.com/.../runners
#   STUB_FAIL_URL         Regex; matching URLs return exit code 6
#   STUB_DESTROYED        Path to append destroyed VMIDs (one per line)
CURL_STUB = r"""#!/usr/bin/env python3
import sys, os, re, json

url = None
method = "GET"
output_file = None
write_out = None
i = 1
while i < len(sys.argv):
    arg = sys.argv[i]
    if arg in ("-X", "--request") and i + 1 < len(sys.argv):
        method = sys.argv[i + 1].upper()
        i += 2
    elif arg in ("-o", "--output") and i + 1 < len(sys.argv):
        output_file = sys.argv[i + 1]
        i += 2
    elif arg in ("-w", "--write-out") and i + 1 < len(sys.argv):
        write_out = sys.argv[i + 1]
        i += 2
    elif re.match(r"https?://", arg):
        url = arg
        i += 1
    else:
        i += 1

if url is None:
    sys.exit(0)

fail_pat = os.environ.get("STUB_FAIL_URL", "")
if fail_pat and re.search(fail_pat, url):
    print(f"curl: (6) Could not resolve host", file=sys.stderr)
    sys.exit(6)

def respond(data, status=0):
    # pvapi.sh calls curl with -o tmpfile -w '%{http_code}': body to file,
    # status code to stdout. Without -o, write body to stdout (old behaviour).
    if output_file:
        with open(output_file, "w") as f:
            f.write(data)
        if write_out == "%{http_code}":
            print("200", end="")
    else:
        print(data)
    sys.exit(status)

# GitHub workflow-run API (owning-run check). Must precede the runners route:
# both live on api.github.com and the runners route is a catch-all.
m = re.search(r"/repos/[^/]+/([^/]+)/actions/runs/(\d+)$", url)
if m:
    key = f"STUB_RUN_{m.group(2)}"
    if key in os.environ:
        respond(os.environ[key])
    print("curl: (22) not found", file=sys.stderr)
    sys.exit(22)

# GitHub runners API
if "api.github.com" in url:
    respond(os.environ.get("STUB_RUNNERS", '{"runners": []}'))

# Proxmox VM list
if re.search(r"/qemu$", url) and method == "GET":
    respond(os.environ.get("STUB_VM_LIST", '{"data": []}'))

# Proxmox VM config
m = re.search(r"/qemu/(\d+)/config", url)
if m:
    vmid = m.group(1)
    default = json.dumps({"data": {"name": f"gh-runner-{vmid}", "meta": ""}})
    respond(os.environ.get(f"STUB_VM_{vmid}_CONFIG", default))

# Proxmox VM current status
m = re.search(r"/qemu/(\d+)/status/current", url)
if m:
    vmid = m.group(1)
    respond(os.environ.get(f"STUB_VM_{vmid}_STATUS", '{"data": {"status": "stopped"}}'))

# Proxmox VM stop
m = re.search(r"/qemu/(\d+)/status/stop", url)
if m:
    respond('{"data": "UPID:test"}')

# Proxmox VM destroy (DELETE)
m = re.search(r"/qemu/(\d+)", url)
if m and method == "DELETE":
    vmid = m.group(1)
    log = os.environ.get("STUB_DESTROYED", "")
    if log:
        with open(log, "a") as f:
            f.write(vmid + "\n")
    respond('{"data": "UPID:destroy"}')

respond("{}")
"""


def _make_vm_list(*entries):
    """entries: (vmid, name) tuples."""
    return json.dumps({"data": [{"vmid": v, "name": n, "status": "running"} for v, n in entries]})


@pytest.fixture
def host(tmp_path):
    """Return (env, destroyed_path).

    Puts a stub curl on PATH and configures minimal reap.sh env vars.
    """
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    stub_curl = stub_dir / "curl"
    stub_curl.write_text(CURL_STUB)
    stub_curl.chmod(0o755)

    destroyed = tmp_path / "destroyed.txt"

    env = {
        **os.environ,
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "PVE_NODE": "pve",
        "PVE_TOKEN_ID": "test@pam!token",
        "PVE_TOKEN_SECRET": "secret123",
        "TEMPLATE_VMID": "101",
        "STUB_DESTROYED": str(destroyed),
        "GITHUB_TOKEN": "gh-test-token",
        "GH_REPO": "owner/repo",
        "STUB_RUNNERS": '{"runners": []}',
    }
    return env, destroyed


def _set_age(env, vmid, epoch):
    """Plant a VM's creation time in the config the stub returns.

    ctime is the only age source since the ledger was removed (db-ulfv): a
    file written by provision.sh cannot be read by a teardown or reap running
    in a different job on a different ephemeral runner. The format is the one
    observed on the real hypervisor.
    """
    env[f"STUB_VM_{vmid}_CONFIG"] = json.dumps({
        "data": {"name": f"gh-runner-{vmid}", "meta": f"creation-qemu=11.0.0,ctime={epoch}"}
    })


def _run(env, max_age_hours=4, extra_args=None):
    cmd = ["bash", str(REAP_SH), "--max-age-hours", str(max_age_hours)]
    if extra_args:
        cmd += extra_args
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _reaped(destroyed_path):
    if not destroyed_path.exists():
        return set()
    return set(destroyed_path.read_text().split())


# ---------------------------------------------------------------------------
# Scenario 1: ctime inside the cutoff → kept
# ---------------------------------------------------------------------------
def test_young_vm_kept(host):
    """A VM whose ctime has not yet reached the cutoff is kept.

    A second VM — past the cutoff — is reaped in the same run, proving the
    reaper ran and reached the age-check rather than failing silently.
    """
    env, destroyed = host
    now = int(time.time())

    vmid_keep = 200
    vmid_reap = 201
    _set_age(env, vmid_keep, now + 7200)        # 2 h in the future
    _set_age(env, vmid_reap, now - 5 * 3600)    # 5 h ago, past the 4 h cutoff

    env["STUB_VM_LIST"] = _make_vm_list((vmid_keep, f"gh-runner-{vmid_keep}"),
                                         (vmid_reap, f"gh-runner-{vmid_reap}"))

    result = _run(env)

    assert result.returncode == 0
    reaped = _reaped(destroyed)
    assert str(vmid_keep) not in reaped, "young VM must not be destroyed"
    assert str(vmid_reap) in reaped, "old VM must be destroyed"


# ---------------------------------------------------------------------------
# Scenario 2: ctime past the cutoff → reaped
# ---------------------------------------------------------------------------
def test_old_vm_reaped(host):
    """A VM whose ctime exceeds the cutoff and is not busy is destroyed."""
    env, destroyed = host
    now = int(time.time())

    vmid = 202
    _set_age(env, vmid, now - 5 * 3600)
    env["STUB_VM_LIST"] = _make_vm_list((vmid, f"gh-runner-{vmid}"))

    result = _run(env)

    assert result.returncode == 0
    assert str(vmid) in _reaped(destroyed)


# ---------------------------------------------------------------------------
# Scenario 3: no ctime in config → skipped, exit non-zero
# ---------------------------------------------------------------------------
def test_no_age_record_skipped_exit_nonzero(host):
    """A VM with no parseable ctime is skipped.

    The exit code must be non-zero so the calling workflow surfaces the
    anomaly. VM_EPOCH=0 (the old behaviour) would reap this VM as a 1970
    orphan, potentially killing a live build with unknown age.
    """
    env, destroyed = host

    vmid = 203
    env["STUB_VM_LIST"] = _make_vm_list((vmid, f"gh-runner-{vmid}"))
    # Config has no ctime — empty meta string
    env[f"STUB_VM_{vmid}_CONFIG"] = json.dumps({
        "data": {"name": f"gh-runner-{vmid}", "meta": ""}
    })

    result = _run(env)

    assert result.returncode != 0, "unknown age must produce a non-zero exit"
    assert str(vmid) not in _reaped(destroyed), "VM with unknown age must not be destroyed"
    # Should name the VM in stderr so the operator knows which one to investigate.
    assert str(vmid) in result.stderr


# ---------------------------------------------------------------------------
# Scenario 4: ctime= in Proxmox config parsed correctly
# ---------------------------------------------------------------------------
def test_config_ctime_fallback_parsed(host):
    """The ctime= field is extracted from the Proxmox config.

    The real Proxmox meta string (host-verified 2026-09-14):
        creation-qemu=11.0.0,ctime=1789270996

    The old code used awk -F'creation=' which never matched — the character
    after 'creation' is '-', not '=', so $2 was always empty and every
    a missing age fell into the VM_EPOCH=0 branch (destroy immediately).

    This test plants the exact observed format and verifies the ctime is
    extracted and used to make the age decision.
    """
    env, destroyed = host
    now = int(time.time())
    old_ctime = now - 5 * 3600

    vmid = 204
    env["STUB_VM_LIST"] = _make_vm_list((vmid, f"gh-runner-{vmid}"))
    meta = f"creation-qemu=11.0.0,ctime={old_ctime}"
    env[f"STUB_VM_{vmid}_CONFIG"] = json.dumps({
        "data": {"name": f"gh-runner-{vmid}", "meta": meta}
    })

    result = _run(env)

    assert result.returncode == 0
    assert str(vmid) in _reaped(destroyed), (
        f"VM with ctime {old_ctime} (>4h ago) must be reaped; "
        f"stderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Scenario 5: Proxmox API enumeration fails → non-zero exit, not silent
# ---------------------------------------------------------------------------
def test_enumeration_failure_exits_nonzero(host):
    """When the Proxmox API call to list VMs fails, exit non-zero.

    The old code used 2>/dev/null on the enumeration and treated an empty
    result as "no VMs found" (exit 0). A curl failure is indistinguishable
    from an empty cluster, and a reaper that reports success while unable to
    enumerate is a reaper that will never report anything else.
    """
    env, _ = host
    # Anchor the pattern to match only the list endpoint, not config/stop/etc.
    env["STUB_FAIL_URL"] = r"/qemu$"

    result = _run(env)

    assert result.returncode != 0, "enumeration failure must produce a non-zero exit"
    assert "no gh-runner" not in result.stderr, (
        "must not report 'no VMs found' when the API call failed"
    )
    # Must say something about the failure so the operator can act.
    assert "failed" in result.stderr or "error" in result.stderr.lower()


# ---------------------------------------------------------------------------
# Scenario 6: GitHub reports runner as busy → kept regardless of age
# ---------------------------------------------------------------------------
def test_busy_runner_kept(host):
    """A VM whose GitHub runner is busy is not destroyed, even past the cutoff.

    Age alone must not authorise destruction; a positive idle-signal from
    GitHub is required. The runner name in the busy check uses the VM name
    (gh-runner-{vmid}), which matches the name provision.sh sets on clone.
    """
    env, destroyed = host
    now = int(time.time())
    old_epoch = now - 5 * 3600

    vmid = 205
    vm_name = f"gh-runner-{vmid}"
    _set_age(env, vmid, old_epoch)
    env["STUB_VM_LIST"] = _make_vm_list((vmid, vm_name))
    env["STUB_RUNNERS"] = json.dumps({
        "runners": [{"name": vm_name, "busy": True, "status": "online"}]
    })

    result = _run(env)

    assert result.returncode == 0
    assert str(vmid) not in _reaped(destroyed), "busy runner VM must not be destroyed"
    assert "busy" in result.stderr


# ---------------------------------------------------------------------------
# Scenario 7: non-runner VMs are never selected
# ---------------------------------------------------------------------------
def test_non_runner_vms_never_selected(host):
    """VMs not named gh-runner-* are never considered for reaping.

    The hypervisor hosts other VMs (Agent-Swarm = 100, Prod-Services = 102).
    Both have names that do not match gh-runner-*; neither must appear in
    the destroyed list regardless of their age. Only the actual runner VM
    may be reaped.
    """
    env, destroyed = host
    now = int(time.time())
    old_epoch = now - 5 * 3600

    runner_vmid = 206
    env["STUB_VM_LIST"] = json.dumps({"data": [
        {"vmid": 100, "name": "Agent-Swarm",   "status": "running"},
        {"vmid": 102, "name": "Prod-Services",  "status": "running"},
        {"vmid": runner_vmid, "name": f"gh-runner-{runner_vmid}", "status": "running"},
    ]})
    _set_age(env, runner_vmid, old_epoch)

    result = _run(env)

    assert result.returncode == 0
    reaped = _reaped(destroyed)
    assert "100" not in reaped, "Agent-Swarm must never be destroyed"
    assert "102" not in reaped, "Prod-Services must never be destroyed"
    assert str(runner_vmid) in reaped, "runner VM should be reaped"


# ---------------------------------------------------------------------------
# Template guard
# ---------------------------------------------------------------------------
def test_template_never_reaped(host):
    """The template VM is never destroyed even if named gh-runner-* and old.

    TEMPLATE_VMID=101 is the default. A template appearing in the pool with
    a runner-style name must be skipped unconditionally.
    """
    env, destroyed = host
    now = int(time.time())
    old_epoch = now - 5 * 3600
    template_vmid = 101

    env["STUB_VM_LIST"] = json.dumps({"data": [
        {"vmid": template_vmid, "name": "gh-runner-101", "status": "stopped"},
    ]})
    _set_age(env, template_vmid, old_epoch)
    env["TEMPLATE_VMID"] = str(template_vmid)

    result = _run(env)

    assert result.returncode == 0
    assert str(template_vmid) not in _reaped(destroyed)


# ---------------------------------------------------------------------------
# Scenario 8: a young VM whose owning run has finished → reaped early
#
# Age alone cannot tell an abandoned clone from a running job, so the age
# cutoff has to sit above the GitHub job ceiling. That left a VM leaked by a
# failed run holding a node's memory for hours. The run id is on the VM, and a
# terminal run cannot acquire another job.
# ---------------------------------------------------------------------------
def test_young_vm_with_finished_run_is_reaped(host):
    env, destroyed = host
    now = int(time.time())

    vmid_orphan = 300   # young, owning run finished an hour ago
    vmid_live = 301     # young, owning run still going

    for vmid, run_id in ((vmid_orphan, "900001"), (vmid_live, "900002")):
        env[f"STUB_VM_{vmid}_CONFIG"] = json.dumps({
            "data": {
                "name": f"gh-runner-{vmid}",
                "meta": f"creation-qemu=11.0.0,ctime={now - 600}",
                "description": f"runner=ci-spira-{run_id}-1 provision_time={now - 600}",
            }
        })

    finished = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 3600))
    env["STUB_RUN_900001"] = json.dumps({"status": "completed", "updated_at": finished})
    env["STUB_RUN_900002"] = json.dumps({"status": "in_progress", "updated_at": finished})
    env["GH_ORG"] = "DeckDumpster"
    env["STUB_VM_LIST"] = _make_vm_list((vmid_orphan, f"gh-runner-{vmid_orphan}"),
                                         (vmid_live, f"gh-runner-{vmid_live}"))

    result = _run(env, max_age_hours=8)

    assert result.returncode == 0, result.stderr
    reaped = _reaped(destroyed)
    assert str(vmid_orphan) in reaped, "a young VM whose run has finished must be reaped"
    assert str(vmid_live) not in reaped, "a young VM whose run is live must be kept"


# ---------------------------------------------------------------------------
# Scenario 9: the grace period keeps the reaper behind teardown
#
# A run reports completed before its `if: always()` teardown has finished.
# Reaping inside that window races teardown and both report a failure for what
# is really a success.
# ---------------------------------------------------------------------------
def test_run_finished_inside_grace_is_kept(host):
    env, destroyed = host
    now = int(time.time())

    vmid_fresh = 310    # run finished 10 s ago — inside the grace window
    vmid_reap = 311     # past the age cutoff, proving the reaper ran

    env[f"STUB_VM_{vmid_fresh}_CONFIG"] = json.dumps({
        "data": {
            "name": f"gh-runner-{vmid_fresh}",
            "meta": f"creation-qemu=11.0.0,ctime={now - 300}",
            "description": f"runner=ci-spira-900003-1 provision_time={now - 300}",
        }
    })
    _set_age(env, vmid_reap, now - 9 * 3600)

    env["STUB_RUN_900003"] = json.dumps({
        "status": "completed",
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 10)),
    })
    env["GH_ORG"] = "DeckDumpster"
    env["STUB_VM_LIST"] = _make_vm_list((vmid_fresh, f"gh-runner-{vmid_fresh}"),
                                         (vmid_reap, f"gh-runner-{vmid_reap}"))

    # With the default grace, the freshly-finished VM is kept.
    env["GH_RUN_GRACE"] = "300"
    result = _run(env, max_age_hours=8)
    assert result.returncode == 0, result.stderr
    reaped = _reaped(destroyed)
    assert str(vmid_fresh) not in reaped, "a run that just finished must stay inside the grace window"
    assert str(vmid_reap) in reaped, "positive control: the aged VM must still be reaped"

    # THE CONTROL THAT MAKES THE ASSERTION ABOVE MEAN SOMETHING. A reaper that
    # ignores the owning run entirely also keeps this VM, for the wrong reason
    # — it is young. Collapsing the grace to zero must flip the verdict; if it
    # does not, the keep above was age doing the work and this test proves
    # nothing about the grace window (law-absence-needs-a-positive-control).
    destroyed.unlink(missing_ok=True)
    env["GH_RUN_GRACE"] = "0"
    result = _run(env, max_age_hours=8)
    assert result.returncode == 0, result.stderr
    reaped = _reaped(destroyed)
    assert str(vmid_fresh) in reaped, \
        "with the grace window closed the finished run must license the reap"

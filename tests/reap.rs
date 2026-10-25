//! Tests for scripts/reap.sh (originally deckdumpster db-hqp).
//!
//! Each test plants a specific offender and verifies the reaper's verdict. A
//! test that asserts "kept" also includes a second VM that IS reaped, proving
//! the reaper ran and made a decision.
//!
//! All API calls (Proxmox + GitHub) are answered by tests/curl-stub.sh on
//! PATH. No hypervisor or network required.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Host {
    dir: PathBuf,
    env: HashMap<String, String>,
    destroyed: PathBuf,
}

impl Drop for Host {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.dir).ok();
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn iso(epoch: i64) -> String {
    let out = Command::new("date")
        .args(["-u", "-d", &format!("@{epoch}"), "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

fn vm_list(entries: &[(i64, &str)]) -> String {
    let items: Vec<String> = entries
        .iter()
        .map(|(v, n)| format!(r#"{{"vmid": {v}, "name": "{n}", "status": "running"}}"#))
        .collect();
    format!(r#"{{"data": [{}]}}"#, items.join(","))
}

fn runner_list(vmid: i64) -> String {
    vm_list(&[(vmid, &format!("gh-runner-{vmid}"))])
}

impl Host {
    fn new(test: &str) -> Host {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let dir = std::env::temp_dir().join(format!("reap-{test}-{}", std::process::id()));
        let stub_dir = dir.join("stub");
        fs::create_dir_all(&stub_dir).unwrap();
        fs::copy(root.join("tests/curl-stub.sh"), stub_dir.join("curl")).unwrap();
        // fs::copy keeps the mode bits.
        let destroyed = dir.join("destroyed.txt");
        let path = format!("{}:{}", stub_dir.display(), std::env::var("PATH").unwrap());
        let env = [
            ("PATH", path.as_str()),
            ("PVE_NODE", "pve"),
            ("PVE_TOKEN_ID", "test@pam!token"),
            ("PVE_TOKEN_SECRET", "secret123"),
            ("TEMPLATE_VMID", "101"),
            ("STUB_DESTROYED", destroyed.to_str().unwrap()),
            ("GITHUB_TOKEN", "gh-test-token"),
            ("GH_REPO", "owner/repo"),
            ("STUB_RUNNERS", r#"{"runners": []}"#),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        Host {
            dir,
            env,
            destroyed,
        }
    }

    fn set(&mut self, k: impl Into<String>, v: impl Into<String>) {
        self.env.insert(k.into(), v.into());
    }

    /// Plant a VM's creation time in the config the stub returns. ctime is the
    /// only age source since the ledger was removed (db-ulfv); the format is
    /// the one observed on the real hypervisor.
    fn set_age(&mut self, vmid: i64, epoch: i64) {
        self.set(
            format!("STUB_VM_{vmid}_CONFIG"),
            format!(
                r#"{{"data": {{"name": "gh-runner-{vmid}", "meta": "creation-qemu=11.0.0,ctime={epoch}"}}}}"#
            ),
        );
    }

    /// Plant a VM young by ctime, owned by workflow run `run_id`.
    fn set_owned(&mut self, vmid: i64, age_secs: i64, run_id: u64) {
        let t = now() - age_secs;
        self.set(
            format!("STUB_VM_{vmid}_CONFIG"),
            format!(
                r#"{{"data": {{"name": "gh-runner-{vmid}", "meta": "creation-qemu=11.0.0,ctime={t}", "description": "runner=ci-spira-{run_id}-1 provision_time={t}"}}}}"#
            ),
        );
    }

    fn run(&self, max_age_hours: u32) -> Output {
        Command::new("bash")
            .arg(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts/reap.sh"))
            .args(["--max-age-hours", &max_age_hours.to_string()])
            .envs(&self.env)
            .output()
            .unwrap()
    }

    fn reaped(&self) -> BTreeSet<String> {
        fs::read_to_string(&self.destroyed)
            .map(|s| s.split_whitespace().map(String::from).collect())
            .unwrap_or_default()
    }
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// A VM whose ctime has not reached the cutoff is kept; a second one past the
/// cutoff is reaped in the same run, proving the age check was reached.
#[test]
fn young_vm_kept() {
    let mut h = Host::new("young");
    h.set_age(200, now() + 7200);
    h.set_age(201, now() - 5 * 3600);
    h.set(
        "STUB_VM_LIST",
        vm_list(&[(200, "gh-runner-200"), (201, "gh-runner-201")]),
    );
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(
        !h.reaped().contains("200"),
        "young VM must not be destroyed"
    );
    assert!(h.reaped().contains("201"), "old VM must be destroyed");
}

#[test]
fn old_vm_reaped() {
    let mut h = Host::new("old");
    h.set_age(202, now() - 5 * 3600);
    h.set("STUB_VM_LIST", runner_list(202));
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(h.reaped().contains("202"));
}

/// No parseable ctime: skipped, exit non-zero, VM named on stderr. VM_EPOCH=0
/// (the old behaviour) would reap it as a 1970 orphan.
#[test]
fn no_age_record_skipped_exit_nonzero() {
    let mut h = Host::new("noage");
    h.set("STUB_VM_LIST", runner_list(203));
    h.set(
        "STUB_VM_203_CONFIG",
        r#"{"data": {"name": "gh-runner-203", "meta": ""}}"#,
    );
    let r = h.run(4);
    assert!(
        !r.status.success(),
        "unknown age must produce a non-zero exit"
    );
    assert!(!h.reaped().contains("203"));
    assert!(stderr(&r).contains("203"));
}

/// The real Proxmox meta string (host-verified 2026-09-14) is
/// `creation-qemu=11.0.0,ctime=1789270996`; the old awk -F'creation=' never
/// matched it.
#[test]
fn config_ctime_parsed() {
    let mut h = Host::new("ctime");
    h.set("STUB_VM_LIST", runner_list(204));
    h.set_age(204, now() - 5 * 3600);
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(h.reaped().contains("204"), "stderr: {}", stderr(&r));
}

/// A failed enumeration is not "no VMs found".
#[test]
fn enumeration_failure_exits_nonzero() {
    let mut h = Host::new("enumfail");
    h.set("STUB_FAIL_URL", "/qemu$");
    let r = h.run(4);
    let err = stderr(&r);
    assert!(
        !r.status.success(),
        "enumeration failure must produce a non-zero exit"
    );
    assert!(!err.contains("no gh-runner"), "{err}");
    assert!(
        err.contains("failed") || err.to_lowercase().contains("error"),
        "{err}"
    );
}

/// Age alone must not authorise destruction of a runner GitHub reports busy.
#[test]
fn busy_runner_kept() {
    let mut h = Host::new("busy");
    h.set_age(205, now() - 5 * 3600);
    h.set("STUB_VM_LIST", runner_list(205));
    h.set(
        "STUB_RUNNERS",
        r#"{"runners": [{"name": "gh-runner-205", "busy": true, "status": "online"}]}"#,
    );
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(
        !h.reaped().contains("205"),
        "busy runner VM must not be destroyed"
    );
    assert!(stderr(&r).contains("busy"));
}

/// VMs not named gh-runner-* (Agent-Swarm = 100, Prod-Services = 102) are
/// never selected, whatever their age.
#[test]
fn non_runner_vms_never_selected() {
    let mut h = Host::new("nonrunner");
    h.set(
        "STUB_VM_LIST",
        vm_list(&[
            (100, "Agent-Swarm"),
            (102, "Prod-Services"),
            (206, "gh-runner-206"),
        ]),
    );
    h.set_age(206, now() - 5 * 3600);
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    let reaped = h.reaped();
    assert!(!reaped.contains("100") && !reaped.contains("102"));
    assert!(reaped.contains("206"), "runner VM should be reaped");
}

/// The template is never destroyed even if named gh-runner-* and old.
#[test]
fn template_never_reaped() {
    let mut h = Host::new("template");
    h.set("STUB_VM_LIST", vm_list(&[(101, "gh-runner-101")]));
    h.set_age(101, now() - 5 * 3600);
    h.set("TEMPLATE_VMID", "101");
    let r = h.run(4);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(!h.reaped().contains("101"));
}

/// A young VM whose owning run has finished is reaped early; one whose run is
/// still going is kept.
#[test]
fn young_vm_with_finished_run_is_reaped() {
    let mut h = Host::new("finishedrun");
    h.set_owned(300, 600, 900001);
    h.set_owned(301, 600, 900002);
    let finished = iso(now() - 3600);
    h.set(
        "STUB_RUN_900001",
        format!(r#"{{"status": "completed", "updated_at": "{finished}"}}"#),
    );
    h.set(
        "STUB_RUN_900002",
        format!(r#"{{"status": "in_progress", "updated_at": "{finished}"}}"#),
    );
    h.set("GH_ORG", "DeckDumpster");
    h.set(
        "STUB_VM_LIST",
        vm_list(&[(300, "gh-runner-300"), (301, "gh-runner-301")]),
    );
    let r = h.run(8);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(
        h.reaped().contains("300"),
        "a young VM whose run has finished must be reaped"
    );
    assert!(
        !h.reaped().contains("301"),
        "a young VM whose run is live must be kept"
    );
}

/// A run reports completed before its `if: always()` teardown has finished;
/// the grace window keeps the reaper behind teardown.
#[test]
fn run_finished_inside_grace_is_kept() {
    let mut h = Host::new("grace");
    h.set_owned(310, 300, 900003);
    h.set_age(311, now() - 9 * 3600);
    h.set(
        "STUB_RUN_900003",
        format!(
            r#"{{"status": "completed", "updated_at": "{}"}}"#,
            iso(now() - 10)
        ),
    );
    h.set("GH_ORG", "DeckDumpster");
    h.set(
        "STUB_VM_LIST",
        vm_list(&[(310, "gh-runner-310"), (311, "gh-runner-311")]),
    );

    h.set("GH_RUN_GRACE", "300");
    let r = h.run(8);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(
        !h.reaped().contains("310"),
        "a run that just finished must stay inside the grace window"
    );
    assert!(
        h.reaped().contains("311"),
        "positive control: the aged VM must still be reaped"
    );

    // Control that gives the keep above meaning (law-absence-needs-a-positive-control):
    // a reaper ignoring the owning run also keeps this VM, because it is young.
    // Closing the grace window must flip the verdict.
    fs::remove_file(&h.destroyed).ok();
    h.set("GH_RUN_GRACE", "0");
    let r = h.run(8);
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(
        h.reaped().contains("310"),
        "with the grace window closed the finished run must license the reap"
    );
}

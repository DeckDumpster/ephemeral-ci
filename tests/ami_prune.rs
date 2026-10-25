//! Tests for scripts/ami-prune.sh (sp-iko19d): given a stubbed account, the
//! pruner removes exactly the superseded, unreferenced runner AMIs.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

const STUB: &str = r#"#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1 $2" in
  "ec2 describe-images") cat "$STUB_DIR/images.json" ;;
  "ec2 describe-instances") cat "$STUB_DIR/instances.json" ;;
  "ec2 describe-launch-templates") cat "$STUB_DIR/lts.json" ;;
  "ec2 describe-launch-template-versions") cat "$STUB_DIR/ltv.json" ;;
  "ec2 deregister-image") ;;
  "ec2 delete-snapshot") ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
[ -n "${STUB_FAIL:-}" ] && [ "$1 $2" = "$STUB_FAIL" ] && exit 1
exit 0
"#;

struct Account {
    dir: PathBuf,
}

impl Drop for Account {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.dir).ok();
    }
}

/// (id, day-of-month created, probe-passed, size GiB)
type Img = (&'static str, u32, bool, u32);

fn image_json(imgs: &[Img]) -> String {
    let items: Vec<String> = imgs
        .iter()
        .map(|(id, day, passed, gib)| {
            let tags = if *passed {
                r#"[{"Key":"spill:probe","Value":"passed"}]"#
            } else {
                "[]"
            };
            format!(
                r#"{{"ImageId":"{id}","CreationDate":"2026-10-{day:02}T00:00:00.000Z","Tags":{tags},"BlockDeviceMappings":[{{"Ebs":{{"SnapshotId":"snap-{id}","VolumeSize":{gib}}}}}]}}"#
            )
        })
        .collect();
    format!(r#"{{"Images":[{}]}}"#, items.join(","))
}

impl Account {
    fn new(test: &str, imgs: &[Img], running: &[&str], lt_image: Option<&str>) -> Account {
        let dir = std::env::temp_dir().join(format!("ami-prune-{test}-{}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        let aws = dir.join("bin/aws");
        fs::write(&aws, STUB).unwrap();
        Command::new("chmod").arg("+x").arg(&aws).status().unwrap();
        fs::write(dir.join("images.json"), image_json(imgs)).unwrap();
        let insts: Vec<String> = running
            .iter()
            .map(|i| format!(r#"{{"ImageId":"{i}"}}"#))
            .collect();
        fs::write(
            dir.join("instances.json"),
            format!(
                r#"{{"Reservations":[{{"Instances":[{}]}}]}}"#,
                insts.join(",")
            ),
        )
        .unwrap();
        fs::write(
            dir.join("lts.json"),
            r#"{"LaunchTemplates":[{"LaunchTemplateId":"lt-1"}]}"#,
        )
        .unwrap();
        let data = lt_image
            .map(|i| format!(r#"{{"ImageId":"{i}"}}"#))
            .unwrap_or("{}".into());
        fs::write(
            dir.join("ltv.json"),
            format!(r#"{{"LaunchTemplateVersions":[{{"LaunchTemplateData":{data}}}]}}"#),
        )
        .unwrap();
        Account { dir }
    }

    fn run(&self, extra: &[&str], fail: &str) -> Output {
        let path = format!(
            "{}:{}",
            self.dir.join("bin").display(),
            std::env::var("PATH").unwrap()
        );
        Command::new("bash")
            .arg(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts/ami-prune.sh"))
            .args(extra)
            .env("PATH", path)
            .env("STUB_DIR", &self.dir)
            .env("STUB_FAIL", fail)
            .env("PUBLISHED_TAGS", "")
            .output()
            .unwrap()
    }

    fn calls(&self, verb: &str) -> BTreeSet<String> {
        fs::read_to_string(self.dir.join("calls"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.strip_prefix(&format!("ec2 {verb} ")))
            .map(|l| l.split_whitespace().nth(1).unwrap().to_string())
            .collect()
    }
}

fn set(v: &[&str]) -> BTreeSet<String> {
    v.iter().map(|s| s.to_string()).collect()
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// Newest two kept, the in-use one and the launch-template one spared even
/// though old; the rest go with their snapshots, and the log names the GiB.
#[test]
fn removes_exactly_the_superseded_and_unreferenced() {
    let a = Account::new(
        "select",
        &[
            ("ami-d1", 1, false, 32),
            ("ami-d2", 2, false, 32),
            ("ami-d3", 3, false, 32),
            ("ami-d4", 4, false, 32),
            ("ami-d5", 5, false, 64),
            ("ami-d6", 6, false, 64),
        ],
        &["ami-d1"],
        Some("ami-d2"),
    );
    let r = a.run(&[], "");
    assert!(r.status.success(), "{}", stderr(&r));
    assert_eq!(a.calls("deregister-image"), set(&["ami-d3", "ami-d4"]));
    assert_eq!(
        a.calls("delete-snapshot"),
        set(&["snap-ami-d3", "snap-ami-d4"])
    );
    let log = stderr(&r);
    assert!(log.contains("removed ami-d3: freed 32 GiB"), "{log}");
    assert!(log.contains("total: 2 image(s), 64 GiB freed"), "{log}");
}

/// The newest probe-passed image is what provision.sh selects: kept even when
/// newer unproven builds have pushed it out of the newest two.
#[test]
fn newest_probe_passed_survives_newer_unproven_builds() {
    let a = Account::new(
        "passed",
        &[
            ("ami-p1", 1, true, 32),
            ("ami-p2", 2, true, 32),
            ("ami-u3", 3, false, 32),
            ("ami-u4", 4, false, 32),
        ],
        &[],
        None,
    );
    let r = a.run(&[], "");
    assert!(r.status.success(), "{}", stderr(&r));
    assert_eq!(a.calls("deregister-image"), set(&["ami-p1"]));
}

/// A failed instance lookup is not an empty in-use list: nothing is removed.
#[test]
fn fails_closed_when_a_lookup_fails() {
    let a = Account::new(
        "closed",
        &[
            ("ami-1", 1, false, 32),
            ("ami-2", 2, false, 32),
            ("ami-3", 3, false, 32),
            ("ami-4", 4, false, 32),
        ],
        &[],
        None,
    );
    let r = a.run(&[], "ec2 describe-instances");
    assert!(!r.status.success());
    assert!(a.calls("deregister-image").is_empty());
    assert!(a.calls("delete-snapshot").is_empty());
}

#[test]
fn dry_run_removes_nothing() {
    let a = Account::new(
        "dry",
        &[
            ("ami-1", 1, false, 32),
            ("ami-2", 2, false, 32),
            ("ami-3", 3, false, 32),
        ],
        &[],
        None,
    );
    let r = a.run(&["--dry-run"], "");
    assert!(r.status.success(), "{}", stderr(&r));
    assert!(a.calls("deregister-image").is_empty());
    assert!(stderr(&r).contains("would deregister ami-1"));
}

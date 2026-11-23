//! scripts/teardown.sh (EC2 path) names why an instance ended: one
//! `instance-end` line, plus a warning when EC2 spot reclaimed it (sp-kqmxk4).
//! A stub `aws` on PATH answers describe-instances / terminate-instances.

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

const TOKEN: &str = "aabbccdd11223344aabbccdd11223344";

struct Run {
    out: Output,
    argv: String,
    summary: String,
}

fn run(test: &str, first_describe: &str) -> Run {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("teardown-end-{test}-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("first.json"), first_describe).unwrap();
    let stub = r#"#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/argv"
case "$1 $2" in
  "ec2 describe-instances")
    n=$(grep -c describe-instances "$STUB_DIR/argv")
    if [ "$n" -le 1 ]; then cat "$STUB_DIR/first.json"
    else echo '{"State":{"Name":"terminated"}}'; fi ;;
  "ec2 terminate-instances") echo '{}' ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
"#;
    let aws = dir.join("aws");
    fs::write(&aws, stub).unwrap();
    Command::new("chmod").arg("+x").arg(&aws).status().unwrap();
    let summary = dir.join("summary.md");
    let out = Command::new("bash")
        .arg(root.join("scripts/teardown.sh"))
        .env("PATH", format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()))
        .env("STUB_DIR", &dir)
        .env("BACKEND", "ec2")
        .env("INSTANCE_ID", "i-0aabbccdd11223344")
        .env("VM_TOKEN", TOKEN)
        .env("RUNNER_LABEL", "ci-repo-1-1")
        .env("SPILL_REGION", "us-west-2")
        .env("EC2_TERMINATE_TIMEOUT", "5")
        .env("EC2_TERMINATE_POLL", "0")
        .env("GITHUB_STEP_SUMMARY", &summary)
        .output()
        .unwrap();
    let r = Run {
        out,
        argv: fs::read_to_string(dir.join("argv")).unwrap_or_default(),
        summary: fs::read_to_string(&summary).unwrap_or_default(),
    };
    fs::remove_dir_all(&dir).ok();
    r
}

fn stderr(r: &Run) -> String {
    String::from_utf8_lossy(&r.out.stderr).into_owned()
}

fn end_line(r: &Run) -> serde_like::Line {
    let err = stderr(r);
    let l = err
        .lines()
        .find(|l| l.contains("ephemeral-ci-run-instance-end "))
        .unwrap_or_else(|| panic!("no instance-end line in:\n{err}"));
    serde_like::Line(l.to_string())
}

/// Minimal field access without a JSON dependency: shell out to jq.
mod serde_like {
    use std::io::Write;
    use std::process::{Command, Stdio};
    pub struct Line(pub String);
    impl Line {
        pub fn field(&self, f: &str) -> String {
            let json = self.0.split("ephemeral-ci-run-instance-end ").nth(1).unwrap();
            let mut c = Command::new("jq")
                .args(["-c", &format!(".{f}")])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            c.stdin.take().unwrap().write_all(json.as_bytes()).unwrap();
            let o = c.wait_with_output().unwrap();
            String::from_utf8(o.stdout).unwrap().trim().to_string()
        }
    }
}

fn info(state: &str, reason: &str, lifecycle: &str) -> String {
    format!(
        r#"{{"State":{{"Name":"{state}"}},"Tags":[{{"Key":"ephemeral-ci:vmtoken","Value":"{TOKEN}"}}],
"LaunchTime":"2026-09-26T00:00:00Z"{reason}{lifecycle}}}"#
    )
}

#[test]
fn spot_reclaimed_instance_is_named_and_warned() {
    let reason = r#","StateReason":{"Code":"Server.SpotInstanceTermination","Message":"Server.SpotInstanceTermination: Spot instance termination"},"StateTransitionReason":"Server.SpotInstanceTermination: x""#;
    let r = run("spot", &info("terminated", reason, r#","InstanceLifecycle":"spot""#));
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("reason_code"), r#""Server.SpotInstanceTermination""#);
    assert_eq!(l.field("market"), r#""spot""#);
    assert_eq!(l.field("state"), r#""terminated""#);
    assert_eq!(l.field("label"), r#""ci-repo-1-1""#);
    assert!(stderr(&r).contains(
        "::warning::runner ci-repo-1-1 was reclaimed by EC2 spot (Server.SpotInstanceTermination)"
    ));
    assert!(r.summary.contains("Server.SpotInstanceTermination"));
}

#[test]
fn running_instance_logs_state_without_warning_and_is_terminated() {
    let r = run("running", &info("running", "", ""));
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("state"), r#""running""#);
    assert_eq!(l.field("market"), r#""on-demand""#);
    assert!(!stderr(&r).contains("::warning::"));
    assert!(r.argv.contains("ec2 terminate-instances"));
}

#[test]
fn client_initiated_shutdown_logs_without_warning() {
    let reason = r#","StateReason":{"Code":"Client.InstanceInitiatedShutdown","Message":"Client.InstanceInitiatedShutdown: Instance initiated shutdown"}"#;
    let r = run("shutdown", &info("terminated", reason, ""));
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("reason_code"), r#""Client.InstanceInitiatedShutdown""#);
    assert!(!stderr(&r).contains("::warning::"));
    assert!(r.summary.is_empty());
}

#[test]
fn missing_state_reason_logs_nulls_and_keeps_exit_code() {
    let r = run("noreason", &info("terminated", "", ""));
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("reason_code"), "null");
    assert_eq!(l.field("reason"), "null");
    assert_eq!(l.field("transition"), "null");
    assert!(!stderr(&r).contains("::warning::"));
}

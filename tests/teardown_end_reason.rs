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

#[derive(Default)]
struct Opts<'a> {
    /// Body `gh api` prints; None = gh exits 1.
    runners: Option<&'a str>,
    org: Option<&'a str>,
    record: Option<&'a str>,
    describe_fails: bool,
    no_instance_id: bool,
    /// Output of the by-label describe (ids, space separated).
    label_ids: Option<&'a str>,
}

fn run(test: &str, first_describe: &str) -> Run {
    run_with(test, first_describe, Opts { org: Some("acme"), ..Default::default() })
}

fn run_with(test: &str, first_describe: &str, o: Opts) -> Run {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("teardown-end-{test}-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("first.json"), first_describe).unwrap();
    let stub = r#"#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DIR/argv"
case "$1 $2" in
  "ec2 describe-instances")
    if [ -n "$STUB_LABEL_IDS" ]; then echo "$STUB_LABEL_IDS" | tr -d '\r'; exit 0; fi
    if [ "$STUB_LABEL_IDS_EMPTY" = 1 ]; then exit 0; fi
    if [ "$STUB_DESCRIBE_FAILS" = 1 ]; then echo "AccessDenied" >&2; exit 254; fi
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
    let gh = r#"#!/bin/sh
printf 'gh %s\n' "$*" >> "$STUB_DIR/argv"
[ -f "$STUB_DIR/runners.json" ] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
cat "$STUB_DIR/runners.json"
"#;
    fs::write(dir.join("gh"), gh).unwrap();
    Command::new("chmod").arg("+x").arg(dir.join("gh")).status().unwrap();
    if let Some(r) = o.runners {
        fs::write(dir.join("runners.json"), r).unwrap();
    }
    let summary = dir.join("summary.md");
    let mut cmd = Command::new("bash");
    cmd.env_remove("RUNNER_ORG").env_remove("RUN_RECORD").env_remove("INSTANCE_ID");
    if let Some(org) = o.org {
        cmd.env("RUNNER_ORG", org);
    }
    if let Some(rec) = o.record {
        cmd.env("RUN_RECORD", rec);
    }
    if !o.no_instance_id {
        cmd.env("INSTANCE_ID", "i-0aabbccdd11223344");
    }
    cmd.env("STUB_DESCRIBE_FAILS", if o.describe_fails { "1" } else { "0" })
        .env("STUB_LABEL_IDS", o.label_ids.unwrap_or(""))
        .env("STUB_LABEL_IDS_EMPTY", if o.no_instance_id && o.label_ids.is_none() { "1" } else { "0" });
    let out = cmd
        .arg(root.join("scripts/teardown.sh"))
        .env("PATH", format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()))
        .env("STUB_DIR", &dir)
        .env("BACKEND", "ec2")
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

#[test]
fn any_server_spot_code_warns_but_not_while_running() {
    let reason = r#","StateReason":{"Code":"Server.SpotInstanceShutdown","Message":"Server.SpotInstanceShutdown: Spot instance shutdown"}"#;
    let gone = run("spot-other", &info("terminated", reason, r#","InstanceLifecycle":"spot""#));
    assert!(stderr(&gone).contains("reclaimed by EC2 spot (Server.SpotInstanceShutdown)"));
    let live = run("spot-running", &info("running", reason, r#","InstanceLifecycle":"spot""#));
    assert_eq!(live.out.status.code(), Some(0), "{}", stderr(&live));
    assert!(!stderr(&live).contains("::warning::"));
    assert!(!live.summary.contains("reclaimed by EC2 spot"));
}

fn runners(entries: &[(&str, &str, bool)]) -> String {
    let rs: Vec<String> = entries
        .iter()
        .map(|(n, st, b)| format!(r#"{{"name":"{n}","status":"{st}","busy":{b}}}"#))
        .collect();
    // Two pages, as `gh api --paginate` prints them: one document per page.
    format!(r#"{{"total_count":{n},"runners":[{}]}}{{"total_count":{n},"runners":[]}}"#, rs.join(","), n = rs.len())
}

fn with_runner(test: &str, body: &str) -> Run {
    run_with(test, &info("running", "", ""), Opts { runners: Some(body), org: Some("acme"), ..Default::default() })
}

fn pos(argv: &str, needle: &str) -> usize {
    argv.lines().position(|l| l.contains(needle)).unwrap_or_else(|| panic!("{needle} not in:\n{argv}"))
}

#[test]
fn runner_online_absent_and_offline_are_named_and_queried_before_terminate() {
    for (state, busy) in [("online", true), ("offline", false)] {
        let body = runners(&[("other", "online", false), ("ci-repo-1-1", state, busy)]);
        let r = with_runner(state, &body);
        assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
        let l = end_line(&r);
        assert_eq!(l.field("runner"), format!("\"{state}\""));
        assert_eq!(l.field("runner_busy"), busy.to_string());
        assert_eq!(l.field("runner_error"), "null");
        assert_ne!(l.field("runner_checked_at"), "null");
        assert!(pos(&r.argv, "gh api orgs/acme/actions/runners") < pos(&r.argv, "terminate-instances"));
    }
    // a name that merely contains the label is not the runner
    let r = with_runner("absent", &runners(&[("ci-repo-1-10", "online", false)]));
    let l = end_line(&r);
    assert_eq!(l.field("runner"), r#""absent""#);
    assert_eq!(l.field("last_online_at"), "null");
}

#[test]
fn online_runner_is_last_online_at_the_check() {
    let r = with_runner("lastonline", &runners(&[("ci-repo-1-1", "online", false)]));
    let l = end_line(&r);
    assert_ne!(l.field("runner_checked_at"), "null");
    assert_eq!(l.field("last_online_at"), l.field("runner_checked_at"));
}

#[test]
fn failing_gh_or_org_lookup_is_unknown_with_error_and_exit_code_unchanged() {
    let r = run_with("ghfail", &info("terminated", "", ""), Opts { org: Some("acme"), ..Default::default() });
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("runner"), r#""unknown""#);
    assert!(l.field("runner_error").contains("Bad credentials"), "{}", l.0);
    let r = run_with("noorg", &info("terminated", "", ""), Opts { runners: Some("{}"), ..Default::default() });
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("runner"), r#""unknown""#);
    assert!(l.field("runner_error").contains("RUNNER_ORG"), "{}", l.0);
}

#[test]
fn describe_failure_keeps_exit_one_and_prints_the_line() {
    let r = run_with("descfail", "", Opts { describe_fails: true, org: Some("acme"), ..Default::default() });
    assert_eq!(r.out.status.code(), Some(1), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("state"), "null");
    assert!(l.field("reason").contains("AccessDenied"), "{}", l.0);
    assert_eq!(l.field("instance_id"), r#""i-0aabbccdd11223344""#);
}

fn lines(r: &Run) -> Vec<String> {
    stderr(r).lines().filter(|l| l.contains("ephemeral-ci-run-instance-end ")).map(String::from).collect()
}

#[test]
fn by_label_prints_one_line_per_id_found_or_one_with_null_id() {
    let body = runners(&[("ci-repo-1-1", "offline", false)]);
    let opts = |ids| Opts { runners: Some(&body), org: Some("acme"), no_instance_id: true, label_ids: ids, ..Default::default() };
    let one = run_with("label1", "", opts(Some("i-0aa")));
    assert_eq!(one.out.status.code(), Some(0), "{}", stderr(&one));
    assert_eq!(lines(&one).len(), 1);
    assert_eq!(end_line(&one).field("runner"), r#""offline""#);
    assert_eq!(end_line(&one).field("instance_id"), r#""i-0aa""#);
    let two = run_with("label2", "", opts(Some("i-0aa i-0bb")));
    assert_eq!(lines(&two).len(), 2);
    assert!(pos(&two.argv, "gh api") < pos(&two.argv, "terminate-instances"));
    let none = run_with("label0", "", opts(None));
    assert_eq!(none.out.status.code(), Some(0), "{}", stderr(&none));
    assert_eq!(lines(&none).len(), 1);
    assert_eq!(end_line(&none).field("instance_id"), "null");
}

#[test]
fn last_online_at_falls_back_to_registration_only_when_it_was_online() {
    let body = runners(&[]);
    let rec = r#"{"registered_at":"2026-11-23T15:00:00Z","registered_status":"online"}"#;
    let r = run_with("rec-online", &info("terminated", "", ""), Opts { runners: Some(&body), org: Some("acme"), record: Some(rec), ..Default::default() });
    let l = end_line(&r);
    assert_eq!(l.field("runner"), r#""absent""#);
    assert_eq!(l.field("registered_at"), r#""2026-11-23T15:00:00Z""#);
    assert_eq!(l.field("last_online_at"), r#""2026-11-23T15:00:00Z""#);
    let rec = r#"{"registered_at":"2026-11-23T15:00:00Z","registered_status":"offline"}"#;
    let r = run_with("rec-offline", &info("terminated", "", ""), Opts { runners: Some(&body), org: Some("acme"), record: Some(rec), ..Default::default() });
    assert_eq!(end_line(&r).field("last_online_at"), "null");
    let r = run_with("rec-bad", &info("terminated", "", ""), Opts { runners: Some(&body), org: Some("acme"), record: Some("{not json"), ..Default::default() });
    assert_eq!(r.out.status.code(), Some(0), "{}", stderr(&r));
    let l = end_line(&r);
    assert_eq!(l.field("registered_at"), "null");
    assert_eq!(l.field("last_online_at"), "null");
}

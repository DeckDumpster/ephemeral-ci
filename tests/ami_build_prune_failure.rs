//! sp-mlqbqr: a prune failure after a successful AMI build is logged by name
//! but never fails the build or hides the new AMI.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

const STUB: &str = r#"#!/usr/bin/env bash
case "$1 $2" in
  "ec2 describe-images") echo '{"Images":[]}' ;;
  "ec2 describe-instances") echo '{"Reservations":[]}' ;;
  "ec2 describe-launch-templates")
    echo "An error occurred (UnauthorizedOperation) when calling the DescribeLaunchTemplates operation" >&2
    exit 254 ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
"#;

#[test]
fn prune_refusal_after_build_leaves_the_build_successful() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("ami-build-prune-fail-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let aws = dir.join("aws");
    fs::write(&aws, STUB).unwrap();
    Command::new("chmod").arg("+x").arg(&aws).status().unwrap();
    let script = root.join("scripts/ami-build.sh");
    let out = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "source {} && prune_after_build && echo BUILD-STEP-OK",
            script.display()
        ))
        .env(
            "PATH",
            format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()),
        )
        .env("PUBLISHED_TAGS", "")
        .output()
        .unwrap();
    fs::remove_dir_all(&dir).ok();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{err}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("BUILD-STEP-OK"));
    assert!(err.contains("describe-launch-templates failed"), "{err}");
    assert!(err.contains("ami-prune failed"), "{err}");
}

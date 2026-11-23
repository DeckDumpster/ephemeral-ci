//! The static CI checks run as one script, `scripts/ci-static.sh`, which is
//! also the `static` row of `.spira/checks.toml` and the `static` testenv
//! tier, so `work submit` refuses a non-executable shebang script in seconds
//! (sp-4rim2v).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn read(rel: &str) -> String {
    fs::read_to_string(Path::new(ROOT).join(rel)).unwrap_or_else(|e| panic!("read {rel}: {e}"))
}

fn run_static(root: &Path) -> Output {
    Command::new("bash")
        .arg(Path::new(ROOT).join("scripts/ci-static.sh"))
        .arg("--root")
        .arg(root)
        .output()
        .expect("run scripts/ci-static.sh")
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("ci-static-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("scripts")).unwrap();
    dir
}

fn write_script(path: &Path, body: &str, mode: u32) {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn shebang_script_without_execute_bit_fails_naming_it() {
    let dir = scratch("nonexec");
    write_script(&dir.join("scripts/good.sh"), "#!/usr/bin/env bash\n:\n", 0o755);
    write_script(&dir.join("scripts/bad.sh"), "#!/usr/bin/env bash\n:\n", 0o644);
    let out = run_static(&dir);
    let text = String::from_utf8_lossy(&out.stdout).to_string()
        + &String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "expected failure: {text}");
    assert!(text.contains("scripts/bad.sh"), "must name the file: {text}");
    assert!(!text.contains("scripts/good.sh"), "good file named: {text}");
}

#[test]
fn executable_script_without_shebang_fails_naming_it() {
    let dir = scratch("noshebang");
    write_script(&dir.join("scripts/bare.sh"), "echo hi\n", 0o755);
    let out = run_static(&dir);
    let text = String::from_utf8_lossy(&out.stdout).to_string()
        + &String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "expected failure: {text}");
    assert!(text.contains("scripts/bare.sh"), "must name the file: {text}");
}

#[test]
fn this_repository_passes_its_own_static_checks() {
    let out = run_static(Path::new(ROOT));
    let text = String::from_utf8_lossy(&out.stdout).to_string()
        + &String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "static checks failed: {text}");
}

#[test]
fn ci_checks_row_and_testenv_tier_all_name_the_script() {
    assert!(
        read(".github/workflows/ci.yml").contains("scripts/ci-static.sh --full"),
        "ci.yml must run the script with --full"
    );
    assert!(
        read(".spira/checks.toml").contains("bash scripts/ci-static.sh"),
        "checks.toml row must run the script"
    );
    assert!(
        read(".spira/testenv.toml").contains("scripts/ci-static.sh"),
        "testenv tier must run the script"
    );
}

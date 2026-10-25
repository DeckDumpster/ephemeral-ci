//! The harness and the public repos carry no Python (per Ryan, 2026-10-20).

use std::path::Path;
use std::process::Command;

pub fn tracked_python(repo: &Path) -> Vec<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["ls-files", "-z", "--", "*.py"])
        .output()
        .expect("run git ls-files");
    assert!(out.status.success(), "git ls-files failed");
    String::from_utf8(out.stdout)
        .unwrap()
        .split('\0')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

#[test]
fn no_tracked_python() {
    let found = tracked_python(Path::new(env!("CARGO_MANIFEST_DIR")));
    assert!(found.is_empty(), "tracked Python files: {found:?}");
}

/// Positive control: the detector must see a *.py when one is tracked.
#[test]
fn detector_sees_a_tracked_py() {
    let dir = std::env::temp_dir().join(format!("no-python-control-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let git = |args: &[&str]| {
        assert!(Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(args)
            .status()
            .unwrap()
            .success());
    };
    git(&["init", "-q"]);
    std::fs::write(dir.join("x.py"), "").unwrap();
    git(&["add", "x.py"]);
    let found = tracked_python(&dir);
    std::fs::remove_dir_all(&dir).ok();
    assert_eq!(found, vec!["x.py".to_string()]);
}

//! What the shipped warm/consumers.json must declare as bake inputs: only a listed
//! lockfile moves `warm-lock-sha`, so only a listed file can trigger a rebake.

use std::path::Path;
use std::process::Command;

/// dumpstar's runner-deps installs sccache from its flake, so a pin change must
/// rebake (sp-ogg91u). Array subtraction compares whole names; jq's `contains`
/// would also accept `nix/flake.nix`.
#[test]
fn dumpstar_flake_is_a_bake_input() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("warm/consumers.json");
    let status = Command::new("jq")
        .arg("-e")
        .arg(
            r#".consumers[] | select(.name == "dumpstar") | .lockfiles as $l
               | ["flake.nix", "flake.lock"] - $l == []"#,
        )
        .arg(&manifest)
        .status()
        .expect("run jq");
    assert!(status.success(), "dumpstar lockfiles must list flake.nix and flake.lock");
}

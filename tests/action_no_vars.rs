//! A composite action cannot read the `vars` or `secrets` contexts: the runner
//! refuses to load an action.yml that does ("Unrecognized named-value: 'vars'").

use std::path::Path;

pub fn forbidden_contexts(yml: &str) -> Vec<String> {
    let mut found = Vec::new();
    for (i, line) in yml.lines().enumerate() {
        let code = line.split('#').next().unwrap_or("");
        if code.contains("${{") && (code.contains("vars.") || code.contains("secrets.")) {
            found.push(format!("line {}: {}", i + 1, line.trim()));
        }
    }
    found
}

#[test]
fn composite_actions_read_no_vars_or_secrets() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for dir in ["provision", "teardown", "warm"] {
        let p = root.join(dir).join("action.yml");
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        let found = forbidden_contexts(&text);
        assert!(found.is_empty(), "{} uses vars/secrets: {found:?}", p.display());
    }
}

/// Positive control: the detector must see an expression that reads vars.
#[test]
fn detector_sees_vars() {
    assert_eq!(forbidden_contexts("a: ${{ vars.X }}\n").len(), 1);
    assert_eq!(forbidden_contexts("a: ${{ inputs.x }}\n").len(), 0);
}

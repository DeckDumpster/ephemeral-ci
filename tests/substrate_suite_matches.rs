//! scripts/test-template-substrate.sh runs under `set -o pipefail`; a pipeline
//! into `grep -q` makes the upstream command take SIGPIPE when grep exits at
//! its first match, so the verdict varies run to run (sp-suxc7q). Matches must
//! read a here-string or a file instead.

use std::path::PathBuf;

/// 1-based numbers of code lines that pipe into `grep -q` (any flag cluster with q).
fn piped_grep_q_lines(script: &str) -> Vec<usize> {
    script
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim_start().starts_with('#'))
        .filter(|(_, l)| {
            l.split('|').skip(1).any(|seg| {
                let mut w = seg.split_whitespace();
                w.next() == Some("grep")
                    && w.take_while(|a| a.starts_with('-') && !a.starts_with("--"))
                        .any(|a| a.contains('q'))
            })
        })
        .map(|(i, _)| i + 1)
        .collect()
}

#[test]
fn detector_flags_a_planted_pipeline_into_grep_q() {
    let planted = "# x | grep -q y\nok\ncat f | grep -qE 'a|b'\nif grep -q a <<<\"$X\"; then\nx | grep -c a\n";
    assert_eq!(piped_grep_q_lines(planted), vec![3]);
}

#[test]
fn substrate_suite_never_pipes_into_grep_q() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts/test-template-substrate.sh");
    let script = std::fs::read_to_string(path).unwrap();
    let lines = piped_grep_q_lines(&script);
    assert!(
        lines.is_empty(),
        "pipeline into grep -q (SIGPIPE under pipefail) at scripts/test-template-substrate.sh lines {lines:?}"
    );
}

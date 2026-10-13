use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Output};

const GENERATIONS: &str = r#"[{"generation":2,"date":"2026-10-12 09:30:00","nixosVersion":"26.11.old","kernelVersion":"6.18.1","configurationRevision":"old-revision","specialisations":[],"current":false},{"generation":12,"date":"2026-10-13 10:45:00","nixosVersion":"26.11.new","kernelVersion":"6.18.2","configurationRevision":"new-revision","specialisations":["gaming","work"],"current":true}]"#;

fn run_generations(script: &str, arguments: &[&str]) -> Output {
    let directory = tempfile::tempdir().unwrap();
    let program = directory.path().join("nixos-rebuild");
    fs::write(&program, format!("#!/bin/sh\n{script}\n")).unwrap();
    fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
    Command::new(env!("CARGO_BIN_EXE_br"))
        .arg("generations")
        .args(arguments)
        .env("PATH", directory.path())
        .output()
        .unwrap()
}

#[test]
fn generations_are_readable_newest_last_and_mark_selected_profile() {
    let output = run_generations(&format!("printf '%s\\n' '{GENERATIONS}'"), &[]);
    assert!(output.status.success(), "{output:?}");
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.find("GENERATION 2 ").unwrap() < text.find("GENERATION 12").unwrap());
    for expected in [
        "Selected system profile",
        "2026-10-13 10:45:00",
        "26.11.new",
        "6.18.2",
        "new-revision",
        "gaming, work",
    ] {
        assert!(text.contains(expected), "{text}");
    }
    assert_eq!(text.matches("Selected system profile").count(), 1);
    assert!(!text.contains('\u{1b}'));
    assert!(output.stderr.is_empty());
}

#[test]
fn json_flag_preserves_raw_data() {
    let output = run_generations(&format!("printf '%s\\n' '{GENERATIONS}'"), &["--json"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, format!("{GENERATIONS}\n").as_bytes());
    assert!(output.stderr.is_empty());
}

#[test]
fn empty_and_malformed_generation_data_are_handled() {
    let output = run_generations("printf '[]'", &[]);
    assert!(output.status.success(), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).contains("No system generations found"));
    let output = run_generations("printf 'invalid JSON'", &[]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("parsing generation list"));
}

#[test]
fn legacy_text_fallback_is_not_used_for_json_requests() {
    let script = "if [ \"$2\" = '--json' ]; then exit 1; fi\nprintf 'Generation  Date\\n1           2026-10-13\\n'";
    let output = run_generations(script, &[]);
    assert!(output.status.success(), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("Generation  Date\n"));
    let output = run_generations(script, &["--json"]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
}

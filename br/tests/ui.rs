use std::process::Command;

#[test]
fn captured_help_and_errors_remain_plain() {
    for (variable, value) in [("NO_COLOR", "1"), ("CLICOLOR", "0"), ("TERM", "dumb")] {
        for arguments in [
            vec!["--help"],
            vec!["install", "vim@"],
            vec!["unknown-command"],
        ] {
            let output = Command::new(env!("CARGO_BIN_EXE_br"))
                .args(&arguments)
                .env_remove("CLICOLOR_FORCE")
                .env(variable, value)
                .output()
                .unwrap();
            assert!(!output.stdout.contains(&0x1b), "{output:?}");
            assert!(!output.stderr.contains(&0x1b), "{output:?}");
            if arguments == ["--help"] {
                assert!(output.status.success());
                assert!(
                    String::from_utf8_lossy(&output.stdout).contains("stage it for the next boot")
                );
            } else {
                assert!(!output.status.success());
            }
        }
    }
}

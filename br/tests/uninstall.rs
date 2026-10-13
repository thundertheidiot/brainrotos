use std::fs;
use std::process::Command;

#[test]
fn invalid_uninstall_requests_leave_package_file_unchanged() {
    for (args, exit_code, message) in [
        (
            vec!["uninstall", "git", "--no-switch"],
            2,
            "unexpected argument",
        ),
        (
            vec!["uninstall", "git", "--switch"],
            2,
            "unexpected argument",
        ),
        (vec!["uninstall", "git", "vim@"], 1, "invalid package"),
        (
            vec!["rm", "git", "vim@7.3"],
            1,
            "packages not in the managed package list",
        ),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let packages = directory.path().join("packages.json");
        let original = b"[  \"git\" ]\n\n";
        fs::write(&packages, original).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_br"))
            .args(&args)
            .env("BR_PACKAGES", &packages)
            .env("BR_STATE", directory.path().join("state.json"))
            .env("BR_LOCK", directory.path().join("br.lock"))
            .output()
            .unwrap();

        assert_eq!(output.status.code(), Some(exit_code), "{output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(message),
            "{output:?}"
        );
        assert_eq!(fs::read(packages).unwrap(), original);
        assert!(!directory.path().join("state.json").exists());
        if exit_code == 2 || message == "invalid package" {
            assert!(!directory.path().join("br.lock").exists());
        }
    }
}

use std::fs;
use std::process::Command;

#[test]
fn removed_switch_flags_are_rejected_before_modifying_packages() {
    let directory = tempfile::tempdir().unwrap();
    let packages = directory.path().join("packages.json");
    let original = b"[  \"git\" ]\n\n";
    fs::write(&packages, original).unwrap();

    for flag in ["--switch", "--no-switch"] {
        let output = Command::new(env!("CARGO_BIN_EXE_br"))
            .args(["install", "ripgrep", flag])
            .env("BR_PACKAGES", &packages)
            .env("BR_STATE", directory.path().join("state.json"))
            .env("BR_LOCK", directory.path().join("br.lock"))
            .output()
            .unwrap();

        assert_eq!(output.status.code(), Some(2), "{output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains(&format!("unexpected argument '{flag}'"))
        );
        assert_eq!(fs::read(&packages).unwrap(), original);
        assert!(!directory.path().join("br.lock").exists());
    }
}

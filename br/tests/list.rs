use std::fs;
use std::process::Command;

#[test]
fn list_prints_package_identities_without_mutating_state() {
    let directory = tempfile::tempdir().unwrap();
    let packages = directory.path().join("packages.json");
    let original = br#"["git",{"name":"vim","version":"7.3","libc":false},"vim",{"name":"vim","version":"8.0"}]"#;
    fs::write(&packages, original).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_br"))
        .arg("list")
        .env("BR_PACKAGES", &packages)
        .env("BR_STATE", directory.path().join("state.json"))
        .env("BR_LOCK", directory.path().join("br.lock"))
        .env("PATH", "")
        .output()
        .unwrap();

    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"git\nvim@7.3\nvim\nvim@8.0\n");
    assert!(output.stderr.is_empty());
    assert_eq!(fs::read(&packages).unwrap(), original);
    assert!(!directory.path().join("br.lock").exists());
    assert!(!directory.path().join("state.json").exists());
}

#[test]
fn list_is_silent_for_missing_or_empty_package_lists() {
    let directory = tempfile::tempdir().unwrap();
    let packages = directory.path().join("packages.json");

    for exists in [false, true] {
        if exists {
            fs::write(&packages, "[]").unwrap();
        }
        let output = Command::new(env!("CARGO_BIN_EXE_br"))
            .arg("list")
            .env("BR_PACKAGES", &packages)
            .output()
            .unwrap();

        assert!(output.status.success(), "{output:?}");
        assert!(output.stdout.is_empty());
        assert!(output.stderr.is_empty());
        assert_eq!(packages.exists(), exists);
    }
}

#[test]
fn list_reports_malformed_packages_without_modifying_them() {
    let directory = tempfile::tempdir().unwrap();
    let packages = directory.path().join("packages.json");
    fs::write(&packages, "not json").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_br"))
        .arg("list")
        .env("BR_PACKAGES", &packages)
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("parsing"));
    assert_eq!(fs::read_to_string(&packages).unwrap(), "not json");
}

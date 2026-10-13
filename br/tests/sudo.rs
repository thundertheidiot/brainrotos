use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;

#[test]
fn mutations_reexec_with_original_arguments_and_br_overrides() {
    if rustix::process::geteuid().is_root() || option_env!("BR_EXECUTABLE").is_some() {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let sudo = directory.path().join("sudo");
    fs::write(&sudo, "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 42\n").unwrap();
    fs::set_permissions(&sudo, fs::Permissions::from_mode(0o755)).unwrap();

    for args in [
        vec!["i", "vim@9.0", "git"],
        vec!["rm", "vim"],
        vec!["up", "--switch", "--branch", "testing"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_br"))
            .args(&args)
            .env_clear()
            .env("PATH", directory.path())
            .env("BR_PACKAGES", directory.path().join("packages.json"))
            .env("BR_STATE", directory.path().join("state.json"))
            .env("BR_LOCK", directory.path().join("br.lock"))
            .env("BR_GCROOT_DIR", directory.path().join("gcroots"))
            .env("BR_CUSTOM", "custom value")
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(42), "{output:?}");
        let output = String::from_utf8(output.stdout).unwrap();
        let lines = output.lines().collect::<Vec<_>>();
        let mut preserved = lines[0]
            .strip_prefix("--preserve-env=")
            .unwrap()
            .split(',')
            .collect::<Vec<_>>();
        preserved.sort_unstable();
        assert_eq!(
            preserved,
            [
                "BR_CUSTOM",
                "BR_GCROOT_DIR",
                "BR_LOCK",
                "BR_PACKAGES",
                "BR_STATE"
            ]
        );
        assert_eq!(lines[1], "--");
        assert_eq!(lines[2], env!("CARGO_BIN_EXE_br"));
        assert_eq!(&lines[3..], args);
        assert!(!directory.path().join("br.lock").exists());
    }
}

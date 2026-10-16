use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use rusqlite::Connection;

fn fixture(path: &Path) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE attrs(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
             CREATE TABLE pairs(attr_id INTEGER NOT NULL, version TEXT NOT NULL,
                                path_id INTEGER NOT NULL, tip INTEGER NOT NULL,
                                PRIMARY KEY(attr_id, version)) WITHOUT ROWID;
             INSERT INTO attrs VALUES (1, 'firefox'), (2, 'firefox-beta'),
                 (3, 'old-firefox'), (4, 'literal_%'), (5, 'literal-other'),
                 (6, 'quote''name');
             INSERT INTO pairs VALUES (1, '9.0', 1, 0), (1, '10.0', 2, 1),
                  (1, '16.0.2', 8, 0), (1, '154.0.1', 9, 0),
                  (1, '155.0', 10, 0), (1, '155.0.1', 11, 0),
                 (2, '11.0', 3, 1), (3, '1.0', 4, 0),
                 (4, '1', 5, 1), (5, '2', 6, 1), (6, '3', 7, 1);",
        )
        .unwrap();
}

fn search(path: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_br"))
        .arg("search")
        .args(args)
        .env("BR_MULTIVERSE_DB", path)
        .env("BR_PACKAGES", path.with_extension("packages"))
        .env("BR_STATE", path.with_extension("state"))
        .env("BR_LOCK", path.with_extension("lock"))
        .env("PATH", "")
        .output()
        .unwrap()
}

#[test]
fn search_groups_versions_and_preserves_database_and_state() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    fixture(&path);
    let original = fs::read(&path).unwrap();
    fs::set_permissions(&path, {
        use std::os::unix::fs::PermissionsExt;
        fs::Permissions::from_mode(0o444)
    })
    .unwrap();

    let output = search(&path, &["FIREFOX"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        output.stdout,
        b"firefox\t10.0\t6\nfirefox-beta\t11.0\t1\nold-firefox\t-\t1\n"
    );
    assert!(output.stderr.is_empty());
    assert_eq!(fs::read(&path).unwrap(), original);
    assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
}

#[test]
fn search_lists_all_version_identities_in_deterministic_order() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    fixture(&path);
    let output = search(&path, &["firefox", "--versions", "--nonexact"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        output.stdout,
        b"firefox@9.0\nfirefox@10.0\nfirefox@16.0.2\nfirefox@154.0.1\nfirefox@155.0\nfirefox@155.0.1\nfirefox-beta@11.0\nold-firefox@1.0\n"
    );
    assert!(output.stderr.is_empty());
}

#[test]
fn versions_defaults_to_exact_names_and_nonexact_can_be_requested() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    fixture(&path);

    let output = search(&path, &["firefox", "--versions"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"firefox@9.0\nfirefox@10.0\nfirefox@16.0.2\nfirefox@154.0.1\nfirefox@155.0\nfirefox@155.0.1\n");

    let output = search(&path, &["firefox", "--versions", "--nonexact"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        output.stdout,
        b"firefox@9.0\nfirefox@10.0\nfirefox@16.0.2\nfirefox@154.0.1\nfirefox@155.0\nfirefox@155.0.1\nfirefox-beta@11.0\nold-firefox@1.0\n"
    );
}

#[test]
fn exact_search_flag_filters_grouped_results_and_is_redundant_with_versions() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    fixture(&path);

    let output = search(&path, &["firefox", "--exact"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"firefox\t10.0\t6\n");

    let output = search(&path, &["firefox", "--versions", "--exact"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"firefox@9.0\nfirefox@10.0\nfirefox@16.0.2\nfirefox@154.0.1\nfirefox@155.0\nfirefox@155.0.1\n");

    let output = search(&path, &["firefox", "--exact", "--nonexact"]);
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn search_treats_wildcards_and_quotes_literally_and_is_silent_for_no_matches() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    fixture(&path);
    for (query, expected) in [
        ("_%", "literal_%\t1\t1\n"),
        ("quote'name", "quote'name\t3\t1\n"),
        ("' OR 1=1 --", ""),
        ("no-such-package", ""),
    ] {
        let output = search(&path, &[query]);
        assert!(output.status.success(), "{output:?}");
        assert_eq!(output.stdout, expected.as_bytes());
        assert!(output.stderr.is_empty());
    }
}

#[test]
fn search_reports_missing_corrupt_and_incompatible_databases_without_modification() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("multiverse.db");
    let output = search(&path, &["firefox"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("opening multiverse index"));
    assert!(!path.exists());

    fs::write(&path, "not sqlite").unwrap();
    let output = search(&path, &["firefox"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("preparing multiverse search"));
    assert_eq!(fs::read(&path).unwrap(), b"not sqlite");

    fs::remove_file(&path).unwrap();
    Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TABLE incompatible(id INTEGER);")
        .unwrap();
    let original = fs::read(&path).unwrap();
    let output = search(&path, &["firefox"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("no such table"));
    assert_eq!(fs::read(&path).unwrap(), original);
}

#[test]
fn search_requires_a_nonempty_query() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("missing.db");
    for args in [&[][..], &[""][..]] {
        let output = search(&path, args);
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(!path.exists());
    }
}

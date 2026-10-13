use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fs::{self, File};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use tempfile::NamedTempFile;

pub(crate) struct Snapshot {
    contents: Option<Vec<u8>>,
    mode: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub(crate) enum Package {
    Plain(String),
    Versioned(VersionedPackage),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub(crate) struct VersionedPackage {
    name: String,
    version: String,
    #[serde(flatten)]
    extra: Map<String, Value>,
}

pub(crate) fn parse(input: &str) -> Result<Package> {
    match input.split_once('@') {
        Some((name, version))
            if !name.is_empty() && !version.is_empty() && !version.contains('@') =>
        {
            Ok(Package::Versioned(VersionedPackage {
                name: name.into(),
                version: version.into(),
                extra: Map::new(),
            }))
        }
        Some(_) => bail!("invalid package {input:?}; expected name@version with non-empty parts"),
        None if input.is_empty() => bail!("package name cannot be empty"),
        None => Ok(Package::Plain(input.into())),
    }
}

fn identity(package: &Package) -> (&str, Option<&str>) {
    match package {
        Package::Plain(name) => (name, None),
        Package::Versioned(package) => (&package.name, Some(&package.version)),
    }
}

pub(crate) fn load(path: &Path) -> Result<Vec<Package>> {
    let contents = match fs::read(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    serde_json::from_slice(&contents).with_context(|| format!("parsing {}", path.display()))
}

pub(crate) fn display(package: &Package) -> String {
    let (name, version) = identity(package);
    version.map_or_else(|| name.to_owned(), |version| format!("{name}@{version}"))
}

pub(crate) fn update(path: &Path, requested: &[Package]) -> Result<()> {
    let mut existing = load(path)?;

    for package in requested {
        let already_present = existing
            .iter()
            .any(|existing_package| identity(existing_package) == identity(package));

        if !already_present {
            existing.push(package.clone());
        }
    }

    atomic_json(path, &existing)
}

pub(crate) fn remove(path: &Path, requested: &[Package]) -> Result<()> {
    let mut existing = load(path)?;

    let missing = requested
        .iter()
        .filter(|package| {
            !existing
                .iter()
                .any(|entry| identity(entry) == identity(package))
        })
        .map(display)
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        bail!(
            "packages not in the managed package list: {}",
            missing.join(", ")
        );
    }

    existing.retain(|entry| {
        !requested
            .iter()
            .any(|package| identity(entry) == identity(package))
    });
    atomic_json(path, &existing)
}

pub(crate) fn snapshot(path: &Path) -> Result<Snapshot> {
    match fs::metadata(path) {
        Ok(metadata) => Ok(Snapshot {
            contents: Some(fs::read(path).with_context(|| format!("reading {}", path.display()))?),
            mode: Some(metadata.permissions().mode()),
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Snapshot {
            contents: None,
            mode: None,
        }),
        Err(error) => {
            Err(error).with_context(|| format!("reading metadata for {}", path.display()))
        }
    }
}

pub(crate) fn restore(path: &Path, snapshot: Snapshot) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", path.display()))?;

    match snapshot.contents {
        Some(contents) => {
            fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
            let mut temp = NamedTempFile::new_in(parent)?;
            temp.write_all(&contents)?;
            temp.as_file().sync_all()?;
            if let Some(mode) = snapshot.mode {
                temp.as_file()
                    .set_permissions(fs::Permissions::from_mode(mode))?;
            }
            temp.persist(path)
                .map_err(|error| error.error)
                .with_context(|| format!("restoring {}", path.display()))?;
        }
        None => match fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| format!("removing {}", path.display()));
            }
        },
    }
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let mode = fs::metadata(path)
        .ok()
        .map(|metadata| metadata.permissions().mode());
    let mut temp = NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(&mut temp, value)?;
    writeln!(temp)?;
    if let Some(mode) = mode {
        temp.as_file()
            .set_permissions(fs::Permissions::from_mode(mode))?;
    }
    temp.persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("replacing {}", path.display()))?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loading_and_display_preserve_order_and_package_identities() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        assert!(load(&path).unwrap().is_empty());
        assert!(!path.exists());

        fs::write(
            &path,
            r#"["git",{"name":"vim","version":"7.3","libc":false},"vim"]"#,
        )
        .unwrap();
        let packages = load(&path).unwrap();
        assert_eq!(
            packages.iter().map(display).collect::<Vec<_>>(),
            ["git", "vim@7.3", "vim"]
        );
        assert_eq!(serde_json::to_value(&packages).unwrap()[1]["libc"], false);

        fs::write(&path, "[]").unwrap();
        assert!(load(&path).unwrap().is_empty());
        fs::write(&path, "not json").unwrap();
        assert!(load(&path).unwrap_err().to_string().contains("parsing"));
    }

    #[test]
    fn parses_plain_and_versioned_packages() {
        assert_eq!(parse("vim").unwrap(), Package::Plain("vim".into()));
        assert_eq!(identity(&parse("vim@7.3").unwrap()), ("vim", Some("7.3")));
        assert!(parse("@7.3").is_err());
        assert!(parse("vim@").is_err());
        assert!(parse("vim@7@3").is_err());
    }

    #[test]
    fn updates_preserve_order_options_and_distinct_versions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        fs::write(
            &path,
            r#"["git",{"name":"vim","version":"7.3","libc":false,"adapterOption":4}]"#,
        )
        .unwrap();
        let requests = [
            parse("vim@7.3").unwrap(),
            parse("vim@8.0").unwrap(),
            parse("vim").unwrap(),
            parse("git").unwrap(),
        ];
        update(&path, &requests).unwrap();
        let value: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(value[0], "git");
        assert_eq!(value[1]["adapterOption"], 4);
        assert_eq!(value[1]["libc"], false);
        assert_eq!(value[2]["version"], "8.0");
        assert_eq!(value[3], "vim");
    }

    #[test]
    fn removal_matches_exact_identities_and_preserves_survivors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        fs::write(
            &path,
            r#"["vim",{"name":"vim","version":"7.3","libc":false},{"name":"vim","version":"8.0","adapterOption":4},"git"]"#,
        ).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();

        remove(&path, &[parse("vim").unwrap(), parse("vim").unwrap()]).unwrap();
        let value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(value.as_array().unwrap().len(), 3);
        assert_eq!(value[0]["version"], "7.3");
        assert_eq!(value[0]["libc"], false);

        remove(&path, &[parse("vim@7.3").unwrap()]).unwrap();
        let value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(
            value,
            serde_json::json!([
                {"name":"vim","version":"8.0","adapterOption":4}, "git"
            ])
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );

        remove(&path, &[parse("vim@8.0").unwrap(), parse("git").unwrap()]).unwrap();
        let value: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(value, serde_json::json!([]));
    }

    #[test]
    fn removal_validates_all_requests_before_writing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        let original = b"[  \"git\" ]\n\n";
        fs::write(&path, original).unwrap();
        let error = remove(&path, &[parse("git").unwrap(), parse("vim@7.3").unwrap()]).unwrap_err();
        assert!(error.to_string().contains("vim@7.3"));
        assert_eq!(fs::read(&path).unwrap(), original);

        fs::remove_file(&path).unwrap();
        assert!(remove(&path, &[parse("git").unwrap()]).is_err());
        assert!(!path.exists());
    }

    #[test]
    fn malformed_file_is_never_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        fs::write(&path, "not json").unwrap();
        assert!(update(&path, &[parse("vim").unwrap()]).is_err());
        assert!(remove(&path, &[parse("vim").unwrap()]).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "not json");
    }

    #[test]
    fn restoring_snapshot_recovers_original_bytes_and_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        fs::write(&path, b"original\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let saved = snapshot(&path).unwrap();
        fs::write(&path, b"changed\n").unwrap();

        restore(&path, saved).unwrap();

        assert_eq!(fs::read(&path).unwrap(), b"original\n");
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }

    #[test]
    fn restoring_absent_snapshot_removes_new_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        let saved = snapshot(&path).unwrap();
        fs::write(&path, b"new\n").unwrap();

        restore(&path, saved).unwrap();

        assert!(!path.exists());
    }
}

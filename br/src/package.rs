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
    if let Some((name, version)) = input.split_once('@') {
        if name.is_empty() || version.is_empty() || version.contains('@') {
            bail!("invalid package {input:?}; expected name@version with non-empty parts");
        }
        Ok(Package::Versioned(VersionedPackage {
            name: name.into(),
            version: version.into(),
            extra: Map::new(),
        }))
    } else if input.is_empty() {
        bail!("package name cannot be empty")
    } else {
        Ok(Package::Plain(input.into()))
    }
}

fn identity(package: &Package) -> (&str, Option<&str>) {
    match package {
        Package::Plain(name) => (name, None),
        Package::Versioned(package) => (&package.name, Some(&package.version)),
    }
}

pub(crate) fn update(path: &Path, requested: &[Package]) -> Result<()> {
    let mut existing: Vec<Package> = if path.exists() {
        serde_json::from_slice(
            &fs::read(path).with_context(|| format!("reading {}", path.display()))?,
        )
        .with_context(|| format!("parsing {}", path.display()))?
    } else {
        Vec::new()
    };
    for package in requested {
        if !existing
            .iter()
            .any(|old| identity(old) == identity(package))
        {
            existing.push(package.clone());
        }
    }
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
    fn malformed_file_is_never_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packages.json");
        fs::write(&path, "not json").unwrap();
        assert!(update(&path, &[parse("vim").unwrap()]).is_err());
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

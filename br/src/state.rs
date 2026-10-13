use crate::system::run_status;
use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};

const DEFAULT_SOURCE: &str = "github:thundertheidiot/brainrotos";
const DEFAULT_CONFIGURATION: &str = "base";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct SourceState {
    pub(crate) source: String,
    #[serde(default)]
    pub(crate) update_ref: Option<String>,
    pub(crate) configuration: String,
    #[serde(default)]
    pub(crate) source_store_path: Option<PathBuf>,
    #[serde(default)]
    pub(crate) pending_generation: Option<PathBuf>,
}

#[derive(Deserialize)]
struct GenerationSource {
    source: String,
    #[serde(default)]
    update_ref: Option<String>,
    configuration: String,
    #[serde(default)]
    source_store_path: Option<PathBuf>,
}

pub(crate) struct MutationLock(std::fs::File);

impl MutationLock {
    pub(crate) fn acquire() -> Result<Self> {
        let path = path_env("BR_LOCK", "/nix/osconfig/br.lock");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)
            .with_context(|| format!("opening lock {}", path.display()))?;

        fs2::FileExt::lock_exclusive(&file).context("locking br operations")?;
        Ok(Self(file))
    }
}

impl Drop for MutationLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

pub(crate) fn path_env(name: &str, default: &str) -> PathBuf {
    std::env::var_os(name).map_or_else(|| default.into(), PathBuf::from)
}

pub(crate) fn package_path() -> PathBuf {
    path_env("BR_PACKAGES", "/nix/osconfig/packages.json")
}

fn state_path() -> PathBuf {
    path_env("BR_STATE", "/nix/osconfig/br-state.json")
}

pub(crate) fn load_optional() -> Result<Option<SourceState>> {
    let path = state_path();

    if path.exists() {
        let contents = fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
        let state: SourceState = serde_json::from_slice(&contents)
            .with_context(|| format!("invalid source state {}", path.display()))?;
        if state.source.is_empty() || state.configuration.is_empty() {
            bail!("source state must include source and configuration");
        }
        return Ok(Some(state));
    }

    let running_metadata = Path::new("/run/current-system/etc/br/source.json");
    if running_metadata.exists() {
        let contents = fs::read(running_metadata)?;
        return source_from_generation_metadata(&contents).map(Some);
    }

    Ok(None)
}

pub(crate) fn running_source() -> Result<SourceState> {
    let path = Path::new("/run/current-system/etc/br/source.json");
    let contents = fs::read(path).context("reading running-generation source metadata")?;
    source_from_generation_metadata(&contents)
}

pub(crate) fn latest_staged_generation(current: &Path) -> Result<Option<(PathBuf, SourceState)>> {
    latest_staged_generation_in(current, Path::new("/nix/var/nix/profiles"))
}

fn latest_staged_generation_in(
    current: &Path,
    profiles_dir: &Path,
) -> Result<Option<(PathBuf, SourceState)>> {
    let Some(current_number) = profile_generation_number(current, profiles_dir) else {
        return Ok(None);
    };

    let mut staged_profiles = fs::read_dir(profiles_dir)
        .with_context(|| format!("reading Nix profiles in {}", profiles_dir.display()))?
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_str()?;
            let number = name.strip_prefix("system-")?.strip_suffix("-link")?;
            let number = number.parse::<u64>().ok()?;
            (number > current_number).then_some((number, entry.path()))
        })
        .collect::<Vec<_>>();
    staged_profiles.sort_unstable_by_key(|(number, _)| *number);

    for (_, profile) in staged_profiles.into_iter().rev() {
        let system = fs::canonicalize(&profile)
            .with_context(|| format!("resolving staged profile {}", profile.display()))?;
        if let Some(source) = source_at_generation(&system)? {
            return Ok(Some((system, source)));
        }
    }

    Ok(None)
}

fn source_at_generation(generation: &Path) -> Result<Option<SourceState>> {
    let path = generation.join("etc/br/source.json");
    match fs::read(&path) {
        Ok(contents) => source_from_generation_metadata(&contents).map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

fn source_from_generation_metadata(contents: &[u8]) -> Result<SourceState> {
    let metadata: GenerationSource =
        serde_json::from_slice(contents).context("invalid running-generation source metadata")?;

    Ok(SourceState {
        source: metadata.source,
        update_ref: metadata.update_ref,
        configuration: metadata.configuration,
        source_store_path: metadata.source_store_path,
        pending_generation: None,
    })
}

pub(crate) fn load() -> Result<SourceState> {
    load_optional()?
        .ok_or_else(|| anyhow!("No pinned OS source is available. Run `br update` first."))
}

pub(crate) fn default() -> SourceState {
    SourceState {
        source: DEFAULT_SOURCE.into(),
        update_ref: Some(DEFAULT_SOURCE.into()),
        configuration: DEFAULT_CONFIGURATION.into(),
        source_store_path: None,
        pending_generation: None,
    }
}

pub(crate) fn default_configuration() -> &'static str {
    DEFAULT_CONFIGURATION
}

pub(crate) fn persist(state: &SourceState) -> Result<()> {
    if let Some(source) = &state.source_store_path {
        let root_dir = path_env("BR_GCROOT_DIR", "/nix/var/nix/gcroots");
        let root_name = source
            .file_name()
            .ok_or_else(|| anyhow!("source path has no store basename"))?;
        let root = root_dir.join(format!("br-source-{}", root_name.to_string_lossy()));
        fs::create_dir_all(&root_dir)?;
        run_status(
            "nix-store",
            &[
                "--add-root",
                root.to_str().ok_or_else(|| anyhow!("non-UTF8 GC root"))?,
                "--indirect",
                "-r",
                source
                    .to_str()
                    .ok_or_else(|| anyhow!("non-UTF8 source path"))?,
            ],
        )?;
    }

    atomic_json(&state_path(), state)
}

pub(crate) fn refresh_pending(state: &mut SourceState) -> bool {
    let Some(pending) = &state.pending_generation else {
        return false;
    };

    let pending = fs::canonicalize(pending).unwrap_or_else(|_| pending.clone());
    let current_path = PathBuf::from("/run/current-system");
    let current = fs::canonicalize(&current_path).unwrap_or(current_path);

    if pending_generation_is_ahead(&pending, &current, Path::new("/nix/var/nix/profiles")) {
        return true;
    }

    state.pending_generation = None;
    false
}

fn pending_generation_is_ahead(pending: &Path, current: &Path, profiles_dir: &Path) -> bool {
    let pending_number = profile_generation_number(pending, profiles_dir);
    let current_number = profile_generation_number(current, profiles_dir);

    match (pending_number, current_number) {
        (Some(pending_number), Some(current_number)) => pending_number > current_number,
        _ => pending != current,
    }
}

fn profile_generation_number(system: &Path, profiles_dir: &Path) -> Option<u64> {
    let system = fs::canonicalize(system).ok()?;

    fs::read_dir(profiles_dir)
        .ok()?
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_str()?;
            let number = name.strip_prefix("system-")?.strip_suffix("-link")?;
            let number = number.parse::<u64>().ok()?;
            (fs::canonicalize(entry.path()).ok()?.as_path() == system).then_some(number)
        })
        .max()
}

pub(crate) fn selected_source(state: &SourceState) -> Result<SourceState> {
    if state.source_store_path.is_some() {
        return Ok(state.clone());
    }
    if let Some(path) = state.source.strip_prefix("path:") {
        return Ok(SourceState {
            source_store_path: Some(path.into()),
            ..state.clone()
        });
    }
    bail!(
        "selected source is not pinned to a local store path; run `br update` to establish a pinned source"
    )
}

pub(crate) fn same_source(left: &SourceState, right: &SourceState) -> bool {
    let left_path = left
        .source_store_path
        .as_deref()
        .or_else(|| left.source.strip_prefix("path:").map(Path::new));
    let right_path = right
        .source_store_path
        .as_deref()
        .or_else(|| right.source.strip_prefix("path:").map(Path::new));

    left.configuration == right.configuration
        && match (left_path, right_path) {
            (Some(left_path), Some(right_path)) => left_path == right_path,
            _ => left.source == right.source,
        }
}

pub(crate) fn source_from_metadata(output: &[u8], reference: &str) -> Result<SourceState> {
    let metadata: Value = serde_json::from_slice(output).context("parsing nix flake metadata")?;

    let path = metadata
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("nix flake metadata did not report a store path"))?;

    let locked_source = metadata
        .get("lockedUrl")
        .and_then(Value::as_str)
        .or_else(|| metadata.get("url").and_then(Value::as_str))
        .unwrap_or(reference);

    let update_reference = metadata
        .get("originalUrl")
        .and_then(Value::as_str)
        .unwrap_or(reference);

    Ok(SourceState {
        source: locked_source.into(),
        update_ref: Some(update_reference.into()),
        configuration: DEFAULT_CONFIGURATION.into(),
        source_store_path: Some(path.into()),
        pending_generation: None,
    })
}

fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    use std::io::Write;
    use tempfile::NamedTempFile;

    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", path.display()))?;

    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let mut temp = NamedTempFile::new_in(parent)?;

    serde_json::to_writer_pretty(&mut temp, value)?;
    writeln!(temp)?;

    temp.persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("replacing {}", path.display()))?;
    fs::File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn running_generation_metadata_restores_its_pinned_source() {
        let metadata = br#"{
            "source":"github:owner/repo?rev=old",
            "update_ref":"github:owner/repo/edge",
            "configuration":"base",
            "source_store_path":"/nix/store/old-source"
        }"#;

        let source = source_from_generation_metadata(metadata).unwrap();

        assert_eq!(source.source, "github:owner/repo?rev=old");
        assert_eq!(source.update_ref.as_deref(), Some("github:owner/repo/edge"));
        assert_eq!(source.configuration, "base");
        assert_eq!(
            source.source_store_path,
            Some(PathBuf::from("/nix/store/old-source"))
        );
        assert_eq!(source.pending_generation, None);
    }

    #[test]
    fn source_comparison_uses_pinned_path_and_configuration() {
        let mut recorded = SourceState {
            source: "github:owner/repo?rev=old".into(),
            update_ref: None,
            configuration: "base".into(),
            source_store_path: Some("/nix/store/source".into()),
            pending_generation: None,
        };
        let running = SourceState {
            source: "github:owner/repo?rev=old".into(),
            update_ref: None,
            configuration: "base".into(),
            source_store_path: Some("/nix/store/source".into()),
            pending_generation: None,
        };

        assert!(same_source(&recorded, &running));

        recorded.configuration = "workstation".into();
        assert!(!same_source(&recorded, &running));
    }

    #[test]
    fn staged_generation_is_not_pending_after_a_later_generation_boots() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let profiles = directory.path().join("profiles");
        fs::create_dir(&profiles).unwrap();

        let previous = directory.path().join("previous-system");
        let current = directory.path().join("current-system");
        let next = directory.path().join("next-system");
        fs::create_dir(&previous).unwrap();
        fs::create_dir(&current).unwrap();
        fs::create_dir(&next).unwrap();

        symlink(&previous, profiles.join("system-43-link")).unwrap();
        symlink(&current, profiles.join("system-44-link")).unwrap();
        symlink(&next, profiles.join("system-45-link")).unwrap();

        assert!(!pending_generation_is_ahead(&previous, &current, &profiles));
        assert!(pending_generation_is_ahead(&next, &current, &profiles));
    }

    #[test]
    fn latest_staged_profile_supplies_its_own_source_metadata() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let profiles = directory.path().join("profiles");
        fs::create_dir(&profiles).unwrap();

        let current = directory.path().join("system-10");
        let stale = directory.path().join("system-11");
        let staged = directory.path().join("system-12");
        for system in [&current, &stale, &staged] {
            fs::create_dir_all(system.join("etc/br")).unwrap();
        }
        fs::write(
            stale.join("etc/br/source.json"),
            br#"{"source":"old","configuration":"base"}"#,
        )
        .unwrap();
        fs::write(
            staged.join("etc/br/source.json"),
            br#"{"source":"updated","configuration":"base"}"#,
        )
        .unwrap();

        symlink(&current, profiles.join("system-10-link")).unwrap();
        symlink(&stale, profiles.join("system-11-link")).unwrap();
        symlink(&staged, profiles.join("system-12-link")).unwrap();

        let (staged_path, source) = latest_staged_generation_in(&current, &profiles)
            .unwrap()
            .unwrap();

        assert_eq!(staged_path, staged);
        assert_eq!(source.source, "updated");
    }
}

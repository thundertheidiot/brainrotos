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

    if pending != current {
        return true;
    }

    state.pending_generation = None;
    false
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
}

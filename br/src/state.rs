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
    std::env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| default.into())
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
        let state: SourceState = serde_json::from_slice(&fs::read(&path)?)
            .with_context(|| format!("invalid source state {}", path.display()))?;
        if state.source.is_empty() || state.configuration.is_empty() {
            bail!("source state must include source and configuration");
        }
        return Ok(Some(state));
    }
    let running = Path::new("/run/current-system/etc/br/source.json");
    if running.exists() {
        let metadata: GenerationSource = serde_json::from_slice(&fs::read(running)?)
            .context("invalid running-generation source metadata")?;
        return Ok(Some(SourceState {
            source: metadata.source,
            update_ref: metadata.update_ref,
            configuration: metadata.configuration,
            source_store_path: metadata.source_store_path,
            pending_generation: None,
        }));
    }
    Ok(None)
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
    if let Some(pending) = &state.pending_generation {
        let pending = fs::canonicalize(pending).unwrap_or_else(|_| pending.clone());
        let current = fs::canonicalize("/run/current-system")
            .unwrap_or_else(|_| PathBuf::from("/run/current-system"));
        if pending == current {
            state.pending_generation = None;
            false
        } else {
            true
        }
    } else {
        false
    }
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
    let source = metadata
        .get("lockedUrl")
        .and_then(Value::as_str)
        .or_else(|| metadata.get("url").and_then(Value::as_str))
        .unwrap_or(reference);
    let update_ref = metadata
        .get("originalUrl")
        .and_then(Value::as_str)
        .unwrap_or(reference);
    Ok(SourceState {
        source: source.into(),
        update_ref: Some(update_ref.into()),
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

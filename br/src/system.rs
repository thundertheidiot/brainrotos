use crate::state::{self, SourceState};
use anyhow::{Context, Result, anyhow, bail};
use dialoguer::Confirm;
use indicatif::{ProgressBar, ProgressStyle};
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;
use std::process::{Command, ExitStatus};
use std::{error::Error, fmt};

const DEFAULT_SOURCE: &str = "github:thundertheidiot/brainrotos";

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Action {
    Boot,
    Switch,
}

#[derive(Debug)]
pub(crate) struct InitialBuildFailure(anyhow::Error);

impl fmt::Display for InitialBuildFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "initial Nix build failed: {:#}", self.0)
    }
}

impl Error for InitialBuildFailure {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(self.0.as_ref())
    }
}

pub(crate) fn resolve_source(reference: &str) -> Result<SourceState> {
    let output = command_output(
        "nix",
        &[
            "--extra-experimental-features",
            "nix-command flakes",
            "flake",
            "metadata",
            "--json",
            reference,
        ],
    )?;

    state::source_from_metadata(&output, reference)
}

pub(crate) fn branch_reference(branch: &str) -> Result<String> {
    if branch.trim().is_empty() || branch.chars().any(char::is_whitespace) {
        bail!("branch name must be non-empty and contain no whitespace");
    }
    Ok(format!("{DEFAULT_SOURCE}/{branch}"))
}

pub(crate) fn pipeline(source: &SourceState, action: Action) -> Result<PathBuf> {
    let src = source
        .source_store_path
        .as_ref()
        .ok_or_else(|| anyhow!("pinned source store path is missing"))?;
    let temp = tempfile::tempdir().context("creating temporary operation root")?;
    let src_path = src
        .to_str()
        .ok_or_else(|| anyhow!("non-UTF8 source store path"))?;

    run_status(
        "nix-store",
        &[
            "--add-root",
            temp.path().join("source").to_str().unwrap(),
            "--indirect",
            "-r",
            src_path,
        ],
    )?;

    let target = format!(
        "{}#nixosConfigurations.{}.config.system.build.toplevel",
        src.display(),
        source.configuration
    );
    let output = command_output(
        "nix",
        &[
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--impure",
            "-I",
            "brainrotos=/nix/osconfig",
            "--no-link",
            "--no-write-lock-file",
            "--no-update-lock-file",
            "--print-out-paths",
            &target,
        ],
    )
    .map_err(InitialBuildFailure)?;

    let output = String::from_utf8(output).map_err(|error| {
        InitialBuildFailure(anyhow!("nix build returned non-UTF8 output: {error}"))
    })?;
    let closure = output
        .lines()
        .last()
        .ok_or_else(|| InitialBuildFailure(anyhow!("nix build returned no output path")))?
        .trim()
        .to_string();

    run_status(
        "nix-store",
        &[
            "--add-root",
            temp.path().join("candidate").to_str().unwrap(),
            "--indirect",
            "-r",
            &closure,
        ],
    )?;

    let current = fs::canonicalize("/run/current-system")
        .unwrap_or_else(|_| PathBuf::from("/run/current-system"));
    run_status("nvd", &["diff", current.to_str().unwrap(), &closure])?;

    if action == Action::Switch {
        confirm_switch()?;
    }

    run_status(
        "nixos-rebuild",
        &[
            "--no-reexec",
            "--store-path",
            &closure,
            if action == Action::Boot {
                "boot"
            } else {
                "switch"
            },
        ],
    )?;

    Ok(closure.into())
}

fn confirm_switch() -> Result<()> {
    if !io::stdin().is_terminal() {
        bail!("switch activation requires interactive confirmation");
    }

    let confirmed = Confirm::new()
        .with_prompt("Activate this system generation now?")
        .default(false)
        .wait_for_newline(true)
        .interact()
        .context("reading switch confirmation")?;

    if !confirmed {
        bail!("switch activation cancelled")
    }

    Ok(())
}

pub(crate) fn generations() -> Result<()> {
    let output = command_output("nixos-rebuild", &["list-generations", "--json"])
        .or_else(|_| command_output("nixos-rebuild", &["list-generations"]))?;

    io::stdout().write_all(&output)?;
    Ok(())
}

fn spinner(message: &str) -> ProgressBar {
    if !io::stderr().is_terminal() {
        return ProgressBar::hidden();
    }
    let bar = ProgressBar::new_spinner();
    bar.set_message(message.to_owned());

    let style = ProgressStyle::with_template("{spinner:.cyan} {msg}")
        .expect("the static spinner template is valid");

    bar.set_style(style);
    bar.enable_steady_tick(std::time::Duration::from_millis(100));

    bar
}

fn command_output(program: &str, args: &[&str]) -> Result<Vec<u8>> {
    let bar = spinner(&format!("Running {program}"));

    let result = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("starting {program}"));
    bar.finish_and_clear();

    let output = result?;
    if !output.status.success() {
        io::stderr().write_all(&output.stderr)?;
        bail!("{program} failed with {}", status_text(output.status));
    }

    Ok(output.stdout)
}

pub(crate) fn run_status(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("starting {program}"))?;

    if !status.success() {
        bail!("{program} failed with {}", status_text(status));
    }

    Ok(())
}

fn status_text(status: ExitStatus) -> String {
    status.code().map_or_else(
        || "signal termination".into(),
        |code| format!("exit code {code}"),
    )
}

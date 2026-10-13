use crate::state::{self, SourceState};
use anyhow::{Context, Result, anyhow, bail};
use dialoguer::Confirm;
use indicatif::{ProgressBar, ProgressStyle};
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::{error::Error, fmt};

const DEFAULT_SOURCE: &str = "github:thundertheidiot/brainrotos";

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Action {
    BuildOnly,
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

    if action == Action::BuildOnly {
        return Ok(closure.into());
    }

    let current = fs::canonicalize("/run/current-system")
        .unwrap_or_else(|_| PathBuf::from("/run/current-system"));
    print_diff(&current, Path::new(&closure))?;

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

fn print_diff(old: &Path, new: &Path) -> Result<()> {
    yansi::whenever(yansi::Condition::from(|| {
        io::stdout().is_terminal()
            && std::env::var_os("NO_COLOR").is_none_or(|value| value.is_empty())
            && yansi::Condition::clicolor()
    }));
    // Avoid immutable SQLite reads while Nix may be updating the store database.
    let report = dix::query_diff_report(old, new, true)
        .map_err(|error| anyhow!("querying system diff: {error:#}"))?;
    write_diff(&mut io::stdout().lock(), old, new, &report)
}

fn write_diff(
    output: &mut impl Write,
    old: &Path,
    new: &Path,
    report: &dix::DiffReport,
) -> Result<()> {
    use std::fmt::Write as _;

    let mut rendered = String::new();
    writeln!(rendered, "<<< {}", old.display())?;
    writeln!(rendered, ">>> {}", new.display())?;
    dix::write_diff_report(&mut rendered, report).context("rendering system diff")?;
    output
        .write_all(rendered.as_bytes())
        .context("writing system diff")
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

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_snapshot() -> dix::StoreSnapshot {
        dix::StoreSnapshot {
            closure: Vec::new(),
            selected: Vec::new(),
        }
    }

    #[test]
    fn diff_output_includes_paths_packages_and_closure_stats() {
        yansi::disable();
        let path = dix::StorePath::try_from(PathBuf::from(
            "/nix/store/0123456789abcdefghijklmnopqrstuv-example-1.0",
        ))
        .unwrap();
        let new = dix::StoreSnapshot {
            closure: vec![dix::store::StorePathInfo::new(
                path.clone(),
                "100 B".parse().unwrap(),
            )],
            selected: vec![path],
        };
        let report = dix::diff_store_snapshots(&empty_snapshot(), &new);
        let mut output = Vec::new();
        write_diff(&mut output, Path::new("/old"), Path::new("/new"), &report).unwrap();
        let output = String::from_utf8(output).unwrap();
        assert!(output.starts_with("<<< /old\n>>> /new\n"));
        assert!(output.contains("ADDED\n[A+] example 1.0"));
        assert!(output.contains("PATHS: 0 -> 1 (+1, -0)"));
        assert!(output.contains("SIZE:"));
        assert!(output.contains("DIFF:"));
        assert!(!output.contains('\u{1b}'));
    }

    #[test]
    fn diff_output_failure_retains_io_error() {
        struct BrokenOutput;
        impl Write for BrokenOutput {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed output"))
            }

            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }

        let report = dix::diff_store_snapshots(&empty_snapshot(), &empty_snapshot());
        let error = write_diff(
            &mut BrokenOutput,
            Path::new("/old"),
            Path::new("/new"),
            &report,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "writing system diff");
        assert_eq!(
            error.downcast_ref::<io::Error>().unwrap().kind(),
            io::ErrorKind::BrokenPipe
        );
    }

    #[test]
    #[ignore = "requires a running NixOS system; run in the test VM"]
    fn system_diff_smoke_test() {
        let old = std::env::var_os("BR_DIFF_OLD")
            .map_or_else(|| PathBuf::from("/run/current-system"), PathBuf::from);
        let new = std::env::var_os("BR_DIFF_NEW")
            .map_or_else(|| PathBuf::from("/run/current-system"), PathBuf::from);
        print_diff(&old, &new).unwrap();

        let missing = tempfile::tempdir().unwrap().path().join("missing-system");
        let error = print_diff(&missing, &new).unwrap_err();
        assert!(error.to_string().contains("querying system diff"));
    }
}

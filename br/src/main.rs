#![warn(clippy::pedantic)]

mod cli;
mod package;
mod state;
mod system;
mod ui;

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use cli::{Cli, Commands};
use package::parse;
use state::MutationLock;
use system::Action;

fn main() {
    if let Err(error) = run(Cli::parse()) {
        ui::status("ERROR", &format!("br: {error:#}"), ui::Tone::Error);
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    use std::io::IsTerminal;
    use std::os::unix::process::CommandExt;

    if cli.command.requires_root() && !rustix::process::geteuid().is_root() {
        // Packaged builds must re-enter the wrapper to restore their tool PATH after sudo.
        let executable = option_env!("BR_EXECUTABLE").map_or_else(
            || std::env::current_exe().context("locating br executable"),
            |path| Ok(std::path::PathBuf::from(path)),
        )?;
        let mut command = std::process::Command::new("sudo");
        let overrides = std::env::vars_os()
            .filter_map(|(name, _)| name.into_string().ok())
            .filter(|name| name.starts_with("BR_"))
            .collect::<Vec<_>>();
        if !overrides.is_empty() {
            command.arg(format!("--preserve-env={}", overrides.join(",")));
        }
        let error = command
            .arg("--")
            .arg(executable)
            .args(std::env::args_os().skip(1))
            .exec();
        return Err(error).context("re-executing br with sudo");
    }

    if !matches!(cli.command, Commands::List | Commands::Generations { .. })
        || std::io::stdout().is_terminal()
    {
        ui::heading(match &cli.command {
            Commands::List => "list",
            Commands::Generations { .. } => "generations",
            Commands::Install { .. } => "install",
            Commands::Uninstall { .. } => "uninstall",
            Commands::Update { .. } => "update",
        });
    }
    match cli.command {
        Commands::List => list_packages(),
        Commands::Generations { json } => system::generations(json),
        Commands::Install { packages } => edit_packages(&packages, package::update),
        Commands::Uninstall { packages } => edit_packages(&packages, package::remove),
        Commands::Update { switch, branch } => update(switch, branch),
    }
}

fn list_packages() -> Result<()> {
    use std::io::{self, IsTerminal, Write};

    let packages = package::load(&state::package_path())?;
    let mut output = io::stdout().lock();
    let terminal = output.is_terminal();
    let color = ui::color_enabled(terminal);
    if terminal {
        writeln!(
            output,
            "\n{}",
            ui::separator(
                "PACKAGES",
                usize::from(dialoguer::console::Term::stdout().size().1).min(80),
                color
            )
        )
        .context("writing package list")?;
    }
    for package in &packages {
        let identity = package::display(package);
        let rendered = if terminal {
            match identity.split_once('@') {
                Some((name, version)) => format!(
                    "   {}@{}",
                    ui::paint(name, ui::Tone::Accent, color),
                    ui::paint(version, ui::Tone::Value, color)
                ),
                None => format!("   {}", ui::paint(&identity, ui::Tone::Accent, color)),
            }
        } else {
            identity
        };
        writeln!(output, "{rendered}").context("writing package list")?;
    }
    if terminal {
        writeln!(output, "\n   {} managed packages", packages.len())
            .context("writing package list")?;
        if packages.is_empty() {
            writeln!(
                output,
                "   No managed packages. Add one with br install <package>."
            )
            .context("writing package list")?;
        }
    }
    Ok(())
}

fn edit_packages(
    packages: &[String],
    edit: fn(&std::path::Path, &[package::Package]) -> Result<()>,
) -> Result<()> {
    let parsed = packages
        .iter()
        .map(|package| parse(package))
        .collect::<Result<Vec<_>>>()?;
    ui::section("PACKAGES");
    ui::detail("Requested", &packages.join(", "));
    let _lock = MutationLock::acquire()?;
    let package_path = state::package_path();
    let package_snapshot = package::snapshot(&package_path)?;
    edit(&package_path, &parsed)?;

    let mut source = state::load()?;
    let running_source = state::running_source()?;
    let staged_generation =
        state::latest_staged_generation(std::path::Path::new("/run/current-system"))?;

    if let Some((_, staged_source)) = staged_generation
        && !state::same_source(&staged_source, &running_source)
    {
        ui::status(
            "WARN",
            "An OS update is staged. This package change will activate the older pinned generation with the updated package list, then build and stage the updated OS generation.",
            ui::Tone::Warning,
        );
        return edit_packages_across_source_change(
            &package_path,
            package_snapshot,
            state::selected_source(&running_source)?,
            state::selected_source(&staged_source)?,
        );
    }

    if !state::same_source(&source, &running_source) {
        source = running_source;
    }
    source.pending_generation = None;

    source = state::selected_source(&source)?;
    match system::pipeline(&source, Action::Switch) {
        Ok(_) => {
            state::persist(&source)?;
            ui::success("Package list updated and system activated.");
            Ok(())
        }
        Err(error) => {
            if let Some(build_error) = error.downcast_ref::<system::InitialBuildFailure>() {
                return restore_packages_after_build_failure(
                    &package_path,
                    package_snapshot,
                    &format!("{build_error:#}"),
                );
            }
            Err(anyhow!(
                "package list was updated, but a later build or activation phase failed: {error:#}"
            ))
        }
    }
}

fn edit_packages_across_source_change(
    package_path: &std::path::Path,
    package_snapshot: package::Snapshot,
    mut running_source: state::SourceState,
    mut updated_source: state::SourceState,
) -> Result<()> {
    ui::section("PINNED GENERATION");
    ui::detail(
        "Source",
        &running_source
            .source_store_path
            .as_deref()
            .unwrap_or(std::path::Path::new(&running_source.source))
            .display()
            .to_string(),
    );

    match system::pipeline(&running_source, Action::Switch) {
        Ok(_) => {}
        Err(error)
            if error
                .downcast_ref::<system::InitialBuildFailure>()
                .is_some() =>
        {
            return restore_packages_after_build_failure(
                package_path,
                package_snapshot,
                &format!("{error:#}"),
            );
        }
        Err(error) => return Err(error),
    }

    ui::section("UPDATED GENERATION");
    ui::detail(
        "Source",
        &updated_source
            .source_store_path
            .as_deref()
            .unwrap_or(std::path::Path::new(&updated_source.source))
            .display()
            .to_string(),
    );

    running_source
        .update_ref
        .clone_from(&updated_source.update_ref);
    running_source
        .pending_generation
        .clone_from(&updated_source.pending_generation);
    state::persist(&running_source).context(
        "the current OS generation was activated, but its source state could not be persisted",
    )?;
    let updated_generation = system::pipeline(&updated_source, Action::Boot).map_err(|error| {
        anyhow!(
            "the current OS generation was activated with the updated package list, but the updated OS generation could not be staged: {error:#}"
        )
    })?;
    updated_source.pending_generation = Some(updated_generation);
    state::persist(&updated_source).map_err(|error| {
        anyhow!(
            "the updated OS generation was staged, but its source state could not be persisted: {error:#}"
        )
    })?;

    ui::success(
        "Package list updated; current generation activated and OS update staged for next boot.",
    );
    Ok(())
}

fn restore_packages_after_build_failure(
    package_path: &std::path::Path,
    package_snapshot: package::Snapshot,
    build_message: &str,
) -> Result<()> {
    match package::restore(package_path, package_snapshot) {
        Ok(()) => Err(anyhow!("{build_message}; package list was restored")),
        Err(restore_error) => Err(anyhow!(
            "{build_message}, and restoring the package list also failed: {restore_error:#}"
        )),
    }
}

fn update(switch: bool, branch: Option<String>) -> Result<()> {
    let _lock = MutationLock::acquire()?;
    let previous = state::load_optional()?.unwrap_or_else(state::default);
    let update_ref = match branch {
        Some(branch) => system::branch_reference(&branch)?,
        None => previous
            .update_ref
            .clone()
            .unwrap_or_else(|| "github:thundertheidiot/brainrotos".into()),
    };
    ui::section("SOURCE");
    ui::detail("Reference", &update_ref);
    let mut candidate = system::resolve_source(&update_ref)?;
    candidate.update_ref = Some(update_ref);
    candidate.configuration = if previous.configuration.is_empty() {
        state::default_configuration().into()
    } else {
        previous.configuration
    };
    let action = if switch { Action::Switch } else { Action::Boot };
    let generation = system::pipeline(&candidate, action)?;
    candidate.pending_generation = (action == Action::Boot).then_some(generation);
    state::persist(&candidate).map_err(|error| {
        anyhow!(
            "system {} successfully, but source state could not be persisted: {error:#}",
            if switch { "activated" } else { "staged" }
        )
    })?;

    let result = if switch {
        "activated"
    } else {
        "staged for next boot"
    };
    ui::success(&format!("OS update {result}."));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_cli_requires_packages_and_rejects_switch_flags() {
        assert!(Cli::try_parse_from(["br", "install", "vim", "--no-switch"]).is_err());
        assert!(Cli::try_parse_from(["br", "install", "vim", "--switch"]).is_err());
        assert!(Cli::try_parse_from(["br", "install"]).is_err());
        assert!(Cli::try_parse_from(["br", "install", "vim"]).is_ok());
        assert!(Cli::try_parse_from(["br", "i", "vim"]).is_ok());
        assert!(Cli::try_parse_from(["br", "update", "--switch"]).is_ok());
    }

    #[test]
    fn uninstall_cli_requires_packages_and_rejects_switch_flags() {
        assert!(Cli::try_parse_from(["br", "uninstall"]).is_err());
        assert!(Cli::try_parse_from(["br", "uninstall", "vim", "--no-switch"]).is_err());
        assert!(Cli::try_parse_from(["br", "uninstall", "vim", "--switch"]).is_err());
        assert!(Cli::try_parse_from(["br", "uninstall", "vim", "git@2.0"]).is_ok());
        assert!(matches!(
            Cli::try_parse_from(["br", "rm", "vim"]).unwrap().command,
            Commands::Uninstall { .. }
        ));
    }

    #[test]
    fn metadata_resolution_retains_locked_store_path() {
        let metadata =
            br#"{"path":"/nix/store/abc-source","lockedUrl":"github:owner/repo?rev=123"}"#;
        let source = state::source_from_metadata(metadata, "github:owner/repo").unwrap();
        assert_eq!(source.source, "github:owner/repo?rev=123");
        assert_eq!(
            source.source_store_path.unwrap(),
            std::path::PathBuf::from("/nix/store/abc-source")
        );
    }

    #[test]
    fn state_source_is_not_refreshed_by_install() {
        let source = state::SourceState {
            source: "github:owner/repo?rev=123".into(),
            update_ref: Some("github:owner/repo/edge".into()),
            configuration: "base".into(),
            source_store_path: Some("/nix/store/abc-source".into()),
            pending_generation: None,
        };
        assert_eq!(
            state::selected_source(&source).unwrap().source,
            source.source
        );
    }

    #[test]
    fn update_branch_selects_a_flake_reference() {
        assert_eq!(
            system::branch_reference("testing").unwrap(),
            "github:thundertheidiot/brainrotos/testing"
        );
        assert!(system::branch_reference("").is_err());
        assert!(system::branch_reference("bad branch").is_err());
    }
}

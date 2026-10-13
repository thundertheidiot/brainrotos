#![warn(clippy::pedantic)]

mod cli;
mod package;
mod state;
mod system;

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use cli::{Cli, Commands};
use package::parse;
use state::MutationLock;
use system::Action;

fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("br: {error:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Commands::Generations => system::generations(),
        Commands::Install {
            packages,
            switch,
            no_switch,
        } => install(&packages, switch, no_switch),
        Commands::Update { switch, branch } => update(switch, branch),
    }
}

fn install(packages: &[String], switch: bool, no_switch: bool) -> Result<()> {
    let parsed = packages
        .iter()
        .map(|package| parse(package))
        .collect::<Result<Vec<_>>>()?;
    let _lock = MutationLock::acquire()?;
    let package_path = state::package_path();
    let package_snapshot = package::snapshot(&package_path)?;
    package::update(&package_path, &parsed)?;

    let mut source = state::load()?;
    let pending = state::refresh_pending(&mut source);

    if !no_switch && pending {
        eprintln!(
            "Warning: an OS update is staged for the next boot. This install will activate the current OS generation with the new packages, then build and stage the updated OS generation."
        );

        let running_source = state::running_source()?;
        let updated_source = state::selected_source(&source)?;

        return install_while_update_is_pending(
            &package_path,
            package_snapshot,
            running_source,
            updated_source,
        );
    }

    let action = match (no_switch, switch, pending) {
        (true, _, _) => Action::BuildOnly,
        (false, true, _) | (false, false, false) => Action::Switch,
        (false, false, true) => Action::Boot,
    };

    source = state::selected_source(&source)?;
    match system::pipeline(&source, action) {
        Ok(generation) => match action {
            Action::BuildOnly => {
                println!(
                    "Package list updated and system generation built; no activation was requested."
                );
                Ok(())
            }
            Action::Boot | Action::Switch => {
                source.pending_generation = (action == Action::Boot).then_some(generation);
                state::persist(&source)?;

                let status = match action {
                    Action::Boot => "staged for next boot",
                    Action::Switch => "activated",
                    Action::BuildOnly => unreachable!(),
                };
                println!("Package list updated and system {status}.");
                Ok(())
            }
        },
        Err(error) => {
            if action == Action::BuildOnly {
                return restore_packages_after_build_failure(
                    &package_path,
                    package_snapshot,
                    &format!("{error:#}"),
                );
            }

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

fn install_while_update_is_pending(
    package_path: &std::path::Path,
    package_snapshot: package::Snapshot,
    mut running_source: state::SourceState,
    mut updated_source: state::SourceState,
) -> Result<()> {
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
            "the current OS generation was activated with the new packages, but the updated OS generation could not be staged: {error:#}"
        )
    })?;
    updated_source.pending_generation = Some(updated_generation);
    state::persist(&updated_source).map_err(|error| {
        anyhow!(
            "the updated OS generation was staged, but its source state could not be persisted: {error:#}"
        )
    })?;

    println!(
        "Package list updated; current generation activated and OS update staged for next boot."
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
    println!("OS update {result}.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_rejects_conflicting_switch_flags() {
        assert!(Cli::try_parse_from(["br", "install", "vim", "--switch", "--no-switch"]).is_err());
        assert!(Cli::try_parse_from(["br", "install"]).is_err());
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

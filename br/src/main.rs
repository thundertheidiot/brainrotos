mod cli;
mod package;
mod state;
mod system;

use anyhow::{Result, anyhow, bail};
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
        } => install(packages, switch, no_switch),
        Commands::Update { switch, branch } => update(switch, branch),
    }
}

fn install(packages: Vec<String>, switch: bool, no_switch: bool) -> Result<()> {
    let parsed = packages
        .iter()
        .map(|package| parse(package))
        .collect::<Result<Vec<_>>>()?;
    let _lock = MutationLock::acquire()?;
    package::update(&state::package_path(), &parsed)?;
    if no_switch {
        println!("Package list updated; no build or activation was requested.");
        return Ok(());
    }

    let mut source = state::load()?;
    let pending = state::refresh_pending(&mut source);
    if pending && !switch {
        eprintln!(
            "Warning: an OS update is pending for the next boot. This install will also be staged; pass --switch to activate immediately."
        );
    }
    let action = if switch || !pending {
        Action::Switch
    } else {
        Action::Boot
    };
    source = state::selected_source(&source)?;
    match system::pipeline(&source, action) {
        Ok(generation) => {
            source.pending_generation = (action == Action::Boot).then_some(generation);
            state::persist(&source)?;
            println!(
                "Package list updated and system {}.",
                if action == Action::Boot {
                    "staged for next boot"
                } else {
                    "activated"
                }
            );
            Ok(())
        }
        Err(error) => Err(anyhow!(
            "package list was updated, but build or activation failed: {error:#}"
        )),
    }
}

fn update(switch: bool, branch: Option<String>) -> Result<()> {
    let _lock = MutationLock::acquire()?;
    let previous = state::load_optional()?.unwrap_or_else(state::default);
    let update_ref = if let Some(branch) = branch {
        system::branch_reference(&branch)?
    } else {
        previous
            .update_ref
            .clone()
            .unwrap_or_else(|| "github:thundertheidiot/brainrotos".into())
    };
    let mut candidate = system::resolve_source(&update_ref)?;
    candidate.update_ref = Some(update_ref);
    candidate.configuration = if previous.configuration.is_empty() {
        state::default_configuration().into()
    } else {
        previous.configuration
    };
    let action = if switch { Action::Switch } else { Action::Boot };
    match system::pipeline(&candidate, action) {
        Ok(generation) => {
            candidate.pending_generation = (action == Action::Boot).then_some(generation);
            if let Err(error) = state::persist(&candidate) {
                bail!(
                    "system {} successfully, but source state could not be persisted: {error:#}",
                    if switch { "activated" } else { "staged" }
                );
            }
            println!(
                "OS update {}.",
                if switch {
                    "activated"
                } else {
                    "staged for next boot"
                }
            );
            Ok(())
        }
        Err(error) => Err(error),
    }
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

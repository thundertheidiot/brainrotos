use clap::{ArgAction, Parser, Subcommand};

fn styles() -> clap::builder::Styles {
    use clap::builder::styling::AnsiColor;
    clap::builder::Styles::styled()
        .header(AnsiColor::Cyan.on_default().bold())
        .usage(AnsiColor::Cyan.on_default().bold())
        .literal(AnsiColor::Magenta.on_default().bold())
        .placeholder(AnsiColor::Cyan.on_default())
        .error(AnsiColor::Red.on_default().bold())
        .valid(AnsiColor::Green.on_default())
        .invalid(AnsiColor::Yellow.on_default())
}

#[derive(Parser)]
#[command(name = "br", version, about = "Manage BrainrotOS packages and generations", styles = styles())]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Commands,
}

/// Commands supported by the `br` executable.
#[derive(Subcommand)]
pub(crate) enum Commands {
    /// Build an OS update and stage it for the next boot.
    #[command(visible_alias = "up")]
    Update {
        /// Activate immediately after interactive confirmation.
        #[arg(long, action = ArgAction::SetTrue)]
        switch: bool,
        /// Update from a specific branch.
        #[arg(long, value_name = "BRANCH")]
        branch: Option<String>,
    },
    /// Add packages to the managed package list and activate the system.
    #[command(visible_alias = "i")]
    Install {
        #[arg(required = true, value_name = "PACKAGE")]
        packages: Vec<String>,
    },
    /// Remove packages from the managed package list and activate the system.
    #[command(visible_alias = "rm")]
    Uninstall {
        #[arg(required = true, value_name = "PACKAGE")]
        packages: Vec<String>,
    },
    /// List packages in the managed package list.
    #[command(visible_alias = "l")]
    List,
    /// Search indexed package names, showing tip versions and version counts.
    #[command(visible_alias = "s")]
    Search {
        /// Literal, case-insensitive substring of a package attribute name.
        #[arg(value_parser = clap::builder::NonEmptyStringValueParser::new())]
        query: String,
        /// List every matching indexed name@version pair instead of grouping.
        #[arg(long)]
        versions: bool,
        /// Match the package attribute name exactly.
        #[arg(long, conflicts_with = "nonexact")]
        exact: bool,
        /// Match package attribute names by substring.
        #[arg(long, conflicts_with = "exact")]
        nonexact: bool,
    },
    /// Show available system generations.
    Generations {
        /// Print raw generation data as JSON.
        #[arg(long)]
        json: bool,
    },
}

impl Commands {
    pub(crate) fn requires_root(&self) -> bool {
        matches!(
            self,
            Self::Install { .. } | Self::Uninstall { .. } | Self::Update { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_mutating_commands_require_root() {
        for args in [
            vec!["br", "install", "vim"],
            vec!["br", "i", "vim"],
            vec!["br", "uninstall", "vim"],
            vec!["br", "rm", "vim"],
            vec!["br", "update"],
            vec!["br", "up", "--switch", "--branch", "testing"],
        ] {
            assert!(Cli::try_parse_from(args).unwrap().command.requires_root());
        }
        for args in [
            vec!["br", "list"],
            vec!["br", "search", "firefox"],
            vec!["br", "search", "firefox", "--versions"],
            vec!["br", "search", "firefox", "--exact", "--versions"],
            vec!["br", "generations"],
            vec!["br", "generations", "--json"],
        ] {
            assert!(!Cli::try_parse_from(args).unwrap().command.requires_root());
        }
    }
}

use clap::{ArgAction, Parser, Subcommand};

#[derive(Parser)]
#[command(name = "br", version, about = "Manage BrainrotOS generations")]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Commands,
}

/// Commands supported by the `br` executable.
#[derive(Subcommand)]
pub(crate) enum Commands {
    #[command(visible_alias = "up")]
    Update {
        #[arg(long, action = ArgAction::SetTrue)]
        switch: bool,
        #[arg(long, value_name = "BRANCH")]
        branch: Option<String>,
    },
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
    List,
    Generations,
}

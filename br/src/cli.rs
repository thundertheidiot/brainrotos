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
        #[arg(long, conflicts_with = "no_switch")]
        switch: bool,
        #[arg(long)]
        no_switch: bool,
    },
    Generations,
}

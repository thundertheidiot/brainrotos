use clap::{ArgAction, Parser, Subcommand};

#[derive(Parser)]
#[command(name = "br", version, about = "Manage BrainrotOS generations")]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Commands,
}

#[derive(Subcommand)]
pub(crate) enum Commands {
    Update {
        #[arg(long, action = ArgAction::SetTrue)]
        switch: bool,
        #[arg(long, value_name = "BRANCH")]
        branch: Option<String>,
    },
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

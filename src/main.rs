use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::Parser;

use rewind::cli::{self, Cli, Command};
use rewind::config::Config;

fn main() -> ExitCode {
    let cli = Cli::parse_from(cli::expand_args(std::env::args()));
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<()> {
    if let Some(path) = &cli.env_file {
        dotenvy::from_path(path)
            .with_context(|| format!("env file not found: {}", path.display()))?;
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("REWIND_LOG")
                .unwrap_or_else(|_| cli.log_filter().into()),
        )
        .with_target(false)
        .init();

    let config = Config::from_env();
    rewind::services::timezone_data::install_local(&config);
    match cli.command {
        Command::Run(args) => {
            let mut config = config;
            if let Some(port) = args.port {
                config.port = port;
            }
            if let Some(host) = args.host {
                config.host = host;
            }
            if let Some(dir) = args.image_storage_dir {
                config.image_storage_dir = Some(dir);
            }
            rewind::server::run(&config, args.migrate)
        }
        Command::Sync(args) => {
            println!("{}", cli::sync(&config, &args)?);
            Ok(())
        }
        Command::Migrate => cli::migrate(&config),
        Command::Users(command) => cli::users(&config, command),
        Command::Sources(command) => cli::sources(&config, &command),
        Command::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Command::Config => {
            cli::show_config(&config);
            Ok(())
        }
    }
}

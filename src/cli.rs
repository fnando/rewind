//! The `rewind` command line.

use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use rusqlite::Connection;

use crate::config::Config;
use crate::db;
use crate::models::{Source, User};
use crate::services::{password, sync};

#[derive(Debug, Parser)]
#[command(
    name = "rewind",
    version,
    about = "Your own watch and listening history"
)]
pub struct Cli {
    /// Dotenv file to load before running.
    #[arg(long, global = true, value_name = "PATH")]
    pub env_file: Option<PathBuf>,

    /// Log verbosity.
    #[arg(long, global = true, value_enum)]
    pub verbose_level: Option<Level>,

    /// Shortcut for --verbose-level=info.
    #[arg(short, long, global = true)]
    pub verbose: bool,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum Level {
    Info,
    Debug,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Start the web server (and the background sync).
    Run(RunArgs),
    /// Run pending database migrations.
    Migrate,
    /// Sync plays from enabled sources.
    Sync(SyncArgs),
    /// Manage users.
    #[command(subcommand)]
    Users(UsersCommand),
    /// Manage connected Jellyfin accounts.
    #[command(subcommand)]
    Sources(SourcesCommand),
    /// Print the version.
    Version,
    /// Print the resolved configuration.
    Config,
}

#[derive(Debug, Args)]
pub struct RunArgs {
    #[arg(long)]
    pub port: Option<u16>,
    #[arg(long)]
    pub host: Option<String>,
    /// Run pending migrations before starting.
    #[arg(long)]
    pub migrate: bool,
    /// Directory to cache proxied cover images in.
    #[arg(long, value_name = "PATH")]
    pub image_storage_dir: Option<PathBuf>,
}

#[derive(Debug, Args)]
pub struct SyncArgs {
    /// Only sync this source id (default: every enabled one).
    #[arg(long)]
    pub source: Option<i64>,
    /// Delete the Jellyfin plays and re-import the full history.
    #[arg(long)]
    pub reset: bool,
    /// Don't ask for confirmation with --reset.
    #[arg(long)]
    pub yes: bool,
}

#[derive(Debug, Subcommand)]
pub enum UsersCommand {
    /// Create a user with a generated password.
    New {
        #[arg(long)]
        username: String,
        #[arg(long)]
        name: Option<String>,
    },
    /// Update a user.
    Update {
        #[arg(long)]
        username: String,
        /// Generate a new password.
        #[arg(long)]
        new_password: bool,
        #[arg(long)]
        name: Option<String>,
        #[arg(long, value_parser = ["stars", "thumbs"])]
        rating_style: Option<String>,
        /// Grant or revoke admin (true/false).
        #[arg(long)]
        admin: Option<bool>,
    },
    /// Delete a user and all their data.
    Delete {
        #[arg(long)]
        username: String,
        #[arg(long)]
        yes: bool,
    },
    /// List users.
    List,
}

#[derive(Debug, Subcommand)]
pub enum SourcesCommand {
    /// List connected sources.
    List,
    /// Enable a source.
    Enable {
        #[arg(long)]
        id: i64,
    },
    /// Disable a source.
    Disable {
        #[arg(long)]
        id: i64,
    },
    /// Delete a source.
    Delete {
        #[arg(long)]
        id: i64,
        #[arg(long)]
        yes: bool,
    },
}

/// Accepts the colon form too: `rewind users:new` = `rewind users new`.
#[must_use]
pub fn expand_args(args: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut out = Vec::new();
    for (index, arg) in args.into_iter().enumerate() {
        if index == 1
            && !arg.starts_with('-')
            && let Some((head, tail)) = arg.split_once(':')
        {
            out.push(head.to_string());
            out.push(tail.to_string());
            continue;
        }
        out.push(arg);
    }
    out
}

impl Cli {
    #[must_use]
    pub fn log_filter(&self) -> &'static str {
        match (self.verbose_level, self.verbose) {
            (Some(Level::Debug), _) => "rewind=debug",
            (Some(Level::Info), _) | (None, true) => "rewind=info",
            (None, false) => "rewind=error",
        }
    }
}

/// Opens the database and refuses to go on with pending migrations, unless
/// `REWIND_AUTO_MIGRATE=1`.
///
/// # Errors
/// When the database can't be opened or is out of date.
pub fn open_db(config: &Config) -> Result<Connection> {
    let conn = db::open(&config.db_path(), config.db_busy_timeout)?;
    if std::env::var("REWIND_AUTO_MIGRATE").as_deref() == Ok("1") {
        db::migrate(&conn)?;
    } else if db::pending(&conn)? > 0 {
        bail!("pending migrations detected; run `rewind migrate` first");
    }
    Ok(conn)
}

fn confirm(prompt: &str) -> Result<()> {
    print!("{prompt} [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().lock().read_line(&mut answer)?;
    if matches!(answer.trim().to_lowercase().as_str(), "y" | "yes") {
        Ok(())
    } else {
        bail!("Aborted.")
    }
}

fn find_user(conn: &Connection, username: &str) -> Result<User> {
    User::find_by_username(conn, username)?.with_context(|| format!("User not found: {username}"))
}

fn find_source(conn: &Connection, id: i64) -> Result<Source> {
    Source::find(conn, id)?.with_context(|| format!("Source not found: {id}"))
}

fn minute(value: Option<&str>) -> String {
    value.and_then(crate::time::parse).map_or_else(
        || "-".into(),
        |ts| ts.strftime("%Y-%m-%d %H:%M").to_string(),
    )
}

/// Runs a `users` subcommand.
///
/// # Errors
/// When the user isn't found, the input is invalid, or the database fails.
pub fn users(config: &Config, command: UsersCommand) -> Result<()> {
    let conn = open_db(config)?;
    match command {
        UsersCommand::New { username, name } => {
            let password = password::generate();
            let user = User::create(&conn, &username, name.as_deref(), &password)
                .context("Could not create user")?;
            println!("\n== User created ==");
            println!("  {:<10} {}", "username:", user.username);
            println!("  {:<10} {password}", "password:");
            if user.admin {
                println!("  {:<10} yes", "admin:");
            }
            println!(
                "\nShare the password with the user. They will be forced to change it on first login."
            );
        }
        UsersCommand::Update {
            username,
            new_password,
            name,
            rating_style,
            admin,
        } => {
            let user = find_user(&conn, &username)?;
            if let Some(name) = &name {
                User::set_name(
                    &conn,
                    user.id,
                    Some(name.as_str()).filter(|n| !n.is_empty()),
                )?;
            }
            if let Some(style) = &rating_style {
                User::set_rating_style(&conn, user.id, style)?;
            }
            if let Some(admin) = admin {
                User::set_admin(&conn, user.id, admin)?;
            }
            let password = new_password.then(password::generate);
            if let Some(password) = &password {
                User::set_password(&conn, user.id, password, true)?;
            }
            println!("\n== User updated ==");
            println!("  {:<10} {}", "username:", user.username);
            if let Some(password) = password {
                println!("  {:<10} {password}", "password:");
            }
        }
        UsersCommand::Delete { username, yes } => {
            let user = find_user(&conn, &username)?;
            if !yes {
                confirm(&format!("Delete {} and all their data?", user.username))?;
            }
            User::delete(&conn, user.id)?;
            println!("Deleted {}.", user.username);
        }
        UsersCommand::List => {
            let users = User::all(&conn)?;
            if users.is_empty() {
                println!("No users yet. Run: rewind users new --username USERNAME");
                return Ok(());
            }
            println!(
                "{:<20} {:<20} {:<17} {:<17} ADMIN",
                "USERNAME", "NAME", "CREATED", "LAST LOGIN"
            );
            for user in users {
                println!(
                    "{:<20} {:<20} {:<17} {:<17} {}",
                    user.username,
                    user.name.as_deref().unwrap_or("-"),
                    minute(Some(&user.created_at)),
                    minute(user.last_login_at.as_deref()),
                    if user.admin { "yes" } else { "no" }
                );
            }
        }
    }
    Ok(())
}

/// Runs a `sources` subcommand.
///
/// # Errors
/// When the source isn't found or the database fails.
pub fn sources(config: &Config, command: &SourcesCommand) -> Result<()> {
    let conn = open_db(config)?;
    match command {
        SourcesCommand::List => {
            let sources = Source::all(&conn)?;
            if sources.is_empty() {
                println!("No sources connected. Users connect Jellyfin from Settings.");
                return Ok(());
            }
            println!(
                "{:<5} {:<10} {:<40} {:<20} {:<8} LAST SYNC",
                "ID", "TYPE", "URL", "USER", "ENABLED"
            );
            for source in sources {
                println!(
                    "{:<5} {:<10} {:<40} {:<20} {:<8} {}",
                    source.id,
                    source.kind,
                    source.url,
                    source.account_label(),
                    if source.enabled { "yes" } else { "no" },
                    minute(source.last_synced_at.as_deref())
                );
            }
        }
        SourcesCommand::Enable { id } | SourcesCommand::Disable { id } => {
            let enable = matches!(command, SourcesCommand::Enable { .. });
            let id = *id;
            let source = find_source(&conn, id)?;
            Source::set_enabled(&conn, source.id, enable)?;
            println!(
                "Source {} {}.",
                source.id,
                if enable { "enabled" } else { "disabled" }
            );
        }
        SourcesCommand::Delete { id, yes } => {
            let source = find_source(&conn, *id)?;
            if !*yes {
                confirm(&format!("Delete source {} ({})?", source.id, source.url))?;
            }
            Source::delete(&conn, source.id)?;
            println!("Deleted source {}.", source.id);
        }
    }
    Ok(())
}

/// Runs `sync`: every enabled source (or one), optionally starting over.
pub fn sync(config: &Config, args: &SyncArgs) -> Result<String> {
    let conn = open_db(config)?;
    let mut sources = match args.source {
        Some(id) => vec![find_source(&conn, id)?],
        None => Source::enabled(&conn)?,
    };
    if args.reset {
        sources.retain(|s| s.enabled);
    }
    if sources.is_empty() {
        bail!("No enabled sources to sync.");
    }
    let key = config.resolved_secret_key()?;

    if !args.reset {
        if let [source] = sources.as_slice()
            && args.source.is_some()
        {
            sync::sync_source(config, &conn, &key, source)
                .with_context(|| format!("Sync failed for source {}", source.id))?;
            return Ok(format!("Synced source {} ({}).", source.id, source.url));
        }
        sync::run_once(config, &conn)?;
        let count = sources.len();
        return Ok(format!(
            "Synced {count} {}.",
            if count == 1 { "source" } else { "sources" }
        ));
    }

    if !args.yes {
        let ids: Vec<String> = sources.iter().map(|s| s.id.to_string()).collect();
        confirm(&format!(
            "Delete every play imported from source {} and re-import from the Rewind plugin?",
            ids.join(", ")
        ))?;
    }
    let removed = sync::reset(&conn, &sources)?;
    for source in &sources {
        if let Err(error) = sync::sync_source(config, &conn, &key, source) {
            println!("Sync failed for source {}: {error:#}", source.id);
        }
    }
    let ids: Vec<String> = sources.iter().map(|s| s.id.to_string()).collect();
    let imported: i64 = conn.query_row(
        &format!(
            "SELECT count(*) FROM plays WHERE source_id IN ({})",
            ids.join(",")
        ),
        [],
        |row| row.get(0),
    )?;
    Ok(format!("Removed {removed} and imported {imported} plays."))
}

/// # Errors
/// When the database can't be opened or a migration fails.
pub fn migrate(config: &Config) -> Result<()> {
    let conn = db::open(&config.db_path(), config.db_busy_timeout)?;
    let ran = db::migrate(&conn)?;
    if ran == 0 {
        println!("Already up to date.");
    } else {
        println!("Migrations complete.");
    }
    Ok(())
}

pub fn show_config(config: &Config) {
    for (key, value) in config.summary() {
        println!("  {:<20} {value}", format!("{key}:"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_the_colon_form() {
        let args = expand_args(["rewind", "users:new", "--username", "x"].map(String::from));
        assert_eq!(args, ["rewind", "users", "new", "--username", "x"]);
        let args = expand_args(["rewind", "--env-file", "a:b"].map(String::from));
        assert_eq!(args, ["rewind", "--env-file", "a:b"]);
    }

    #[test]
    fn parses() {
        Cli::try_parse_from(["rewind", "sync", "--reset", "--yes", "--source", "2"]).unwrap();
        Cli::try_parse_from([
            "rewind",
            "users",
            "update",
            "--username",
            "x",
            "--admin",
            "true",
        ])
        .unwrap();
    }
}

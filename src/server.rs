//! `rewind run`: the web server plus the background sync and tzdata threads.

use std::net::SocketAddr;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};

use crate::config::Config;
use crate::db::{self, Db};
use crate::services::{sync, timezone_data};
use crate::web;

/// Wakes sleeping background threads early on shutdown.
#[derive(Clone, Default)]
pub struct Stop(Arc<(Mutex<bool>, Condvar)>);

impl Stop {
    pub fn trigger(&self) {
        let (lock, cvar) = &*self.0;
        if let Ok(mut stopped) = lock.lock() {
            *stopped = true;
        }
        cvar.notify_all();
    }

    /// Sleeps up to `duration`; returns true when stopping.
    #[must_use]
    pub fn wait(&self, duration: Duration) -> bool {
        let (lock, cvar) = &*self.0;
        let Ok(guard) = lock.lock() else { return true };
        if *guard {
            return true;
        }
        cvar.wait_timeout(guard, duration)
            .map_or(true, |(stopped, _)| *stopped)
    }
}

pub fn run(config: &Config, migrate: bool) -> Result<()> {
    {
        let conn = db::open(&config.db_path(), config.db_busy_timeout)?;
        if migrate || std::env::var("REWIND_AUTO_MIGRATE").as_deref() == Ok("1") {
            db::migrate(&conn)?;
        } else if db::pending(&conn)? > 0 {
            anyhow::bail!("Pending migrations detected. Run `rewind migrate` or pass --migrate.");
        }
    }

    let db = Db::new(config.db_path(), config.db_busy_timeout)?;
    let state = web::AppState::new(config.clone(), db.clone())?;
    let stop = Stop::default();
    let threads = vec![
        spawn_sync(config.clone(), db, stop.clone()),
        spawn_tzdata(config.clone(), stop.clone()),
    ];

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .with_context(|| format!("invalid address {}:{}", config.host, config.port))?;
    let shown = if matches!(config.host.as_str(), "0.0.0.0" | "::") {
        "localhost"
    } else {
        &config.host
    };
    println!("Rewind listening on http://{shown}:{}/", config.port);

    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(async move {
            let listener = tokio::net::TcpListener::bind(addr).await?;
            axum::serve(listener, web::app(state))
                .with_graceful_shutdown(shutdown_signal())
                .await
        })?;

    stop.trigger();
    for thread in threads {
        let _ = thread.join();
    }
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = term => {},
    }
    tracing::info!("shutting down");
}

/// Syncs every enabled source, then sleeps `sync_interval`, forever.
fn spawn_sync(config: Config, db: Db, stop: Stop) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("sync".into())
        .spawn(move || {
            loop {
                let result = db
                    .get()
                    .and_then(|conn| sync::run_once(&config, &conn).map(|_| ()));
                if let Err(error) = result {
                    tracing::error!("[sync] {error:#}");
                }
                if stop.wait(Duration::from_secs(config.sync_interval.max(1))) {
                    break;
                }
            }
        })
        .expect("spawn sync thread")
}

/// Checks for newer tzdata once a day.
fn spawn_tzdata(config: Config, stop: Stop) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("tzdata".into())
        .spawn(move || {
            loop {
                if stop.wait(timezone_data::until_due(&config)) {
                    break;
                }
                if let Err(error) = timezone_data::check_and_update(&config) {
                    tracing::error!("[tzdata] {error:#}");
                }
            }
        })
        .expect("spawn tzdata thread")
}

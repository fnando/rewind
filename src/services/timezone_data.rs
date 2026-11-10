//! Keeps the time zone database current on a long-running server without new
//! releases. Once a day it checks the `tzdata` package on PyPI (compiled TZif
//! files that follow IANA releases) and, when newer, unpacks it into the data
//! dir and swaps it in at runtime. A state file keeps the daily cadence
//! across restarts. Any failure leaves the current database in place.

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::RwLock;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use jiff::tz::TimeZoneDatabase;
use serde_json::{Value, json};

use super::http;
use crate::config::Config;
use crate::time;

pub const CHECK_INTERVAL: Duration = Duration::from_hours(24);

static VERSION: RwLock<Option<String>> = RwLock::new(None);

/// The downloaded tzdata version in use, if any.
#[must_use]
pub fn current_version() -> Option<String> {
    VERSION.read().ok().and_then(|v| v.clone())
}

fn state_path(config: &Config) -> PathBuf {
    config.tzdata_dir().join("state.json")
}

fn read_state(config: &Config) -> Value {
    std::fs::read_to_string(state_path(config))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}))
}

fn update_state(config: &Config, key: &str, value: &str) -> Result<()> {
    let mut state = read_state(config);
    state[key] = json!(value);
    std::fs::create_dir_all(config.tzdata_dir())?;
    std::fs::write(state_path(config), serde_json::to_string_pretty(&state)?)?;
    Ok(())
}

fn zoneinfo_dir(config: &Config, version: &str) -> PathBuf {
    config.tzdata_dir().join(version).join("zoneinfo")
}

/// Loads the downloaded copy on boot, if there is one. A bad copy never
/// breaks boot; the built-in database stays.
pub fn install_local(config: &Config) {
    let Some(version) = read_state(config)["installed_version"]
        .as_str()
        .map(String::from)
    else {
        return;
    };
    match load(&zoneinfo_dir(config, &version)) {
        Ok(db) => {
            time::set_tzdb(db);
            set_version(&version);
            tracing::info!("[tzdata] using synced data {version}");
        }
        Err(error) => tracing::error!("[tzdata] load failed: {error:#}"),
    }
}

fn set_version(version: &str) {
    if let Ok(mut current) = VERSION.write() {
        *current = Some(version.to_string());
    }
}

fn load(dir: &Path) -> Result<TimeZoneDatabase> {
    let db = TimeZoneDatabase::from_dir(dir)?;
    if db.get("America/New_York").is_err() {
        bail!("{} isn't a zoneinfo directory", dir.display());
    }
    Ok(db)
}

/// How long until the next check is due.
#[must_use]
pub fn until_due(config: &Config) -> Duration {
    let Some(last) = read_state(config)["last_checked_at"]
        .as_str()
        .and_then(time::parse)
    else {
        return Duration::ZERO;
    };
    let elapsed = time::now().duration_since(last).unsigned_abs();
    CHECK_INTERVAL.saturating_sub(elapsed)
}

/// Compares "2025.2"-style versions numerically.
fn newer(candidate: &str, baseline: Option<&str>) -> bool {
    let parse = |v: &str| -> Vec<u64> { v.split('.').map(|p| p.parse().unwrap_or(0)).collect() };
    baseline.is_none_or(|b| parse(candidate) > parse(b))
}

/// Checks PyPI and installs a newer release. Records the attempt either way,
/// so a failed check still counts toward the daily cadence. Returns the
/// installed version when it changed.
pub fn check_and_update(config: &Config) -> Result<Option<String>> {
    let latest = fetch_latest(config);
    update_state(config, "last_checked_at", &time::format(time::now()))?;
    let Some((version, url)) = latest? else {
        return Ok(None);
    };
    let installed = read_state(config)["installed_version"]
        .as_str()
        .map(String::from);
    if !newer(&version, installed.as_deref()) {
        return Ok(None);
    }
    let response = http::get(&url).timeout(Duration::from_secs(60)).send()?;
    if !response.ok() {
        bail!(
            "download failed for tzdata {version}: HTTP {}",
            response.status
        );
    }
    let dest = zoneinfo_dir(config, &version);
    extract(&response.body, &dest)?;
    let db = load(&dest)?;
    time::set_tzdb(db);
    set_version(&version);
    update_state(config, "installed_version", &version)?;
    if let Some(old) = installed {
        let _ = std::fs::remove_dir_all(config.tzdata_dir().join(old));
    }
    tracing::info!("[tzdata] updated time zone data to {version}");
    Ok(Some(version))
}

/// The latest release's version and wheel URL.
fn fetch_latest(config: &Config) -> Result<Option<(String, String)>> {
    let response = http::get(&config.tzdata_url)
        .timeout(Duration::from_secs(30))
        .send()?;
    if !response.ok() {
        return Ok(None);
    }
    let data: Value = response.json()?;
    let Some(version) = data.pointer("/info/version").and_then(Value::as_str) else {
        return Ok(None);
    };
    let wheel = data["urls"].as_array().and_then(|urls| {
        urls.iter().find(|u| u["packagetype"] == "bdist_wheel")?["url"]
            .as_str()
            .map(String::from)
    });
    Ok(wheel.map(|url| (version.to_string(), url)))
}

/// Unpacks `tzdata/zoneinfo/**` from the wheel into `dest`.
fn extract(wheel: &[u8], dest: &Path) -> Result<()> {
    let incoming = dest.with_extension("incoming");
    let _ = std::fs::remove_dir_all(&incoming);
    let mut archive =
        zip::ZipArchive::new(Cursor::new(wheel)).context("tzdata wheel isn't a zip")?;
    let mut files = 0;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let Some(name) = entry.enclosed_name() else {
            continue;
        };
        let Ok(relative) = name.strip_prefix("tzdata/zoneinfo") else {
            continue;
        };
        if entry.is_dir() || relative.as_os_str().is_empty() {
            continue;
        }
        let target = incoming.join(relative);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        std::fs::write(target, bytes)?;
        files += 1;
    }
    if files == 0 {
        bail!("tzdata wheel has no zoneinfo files");
    }
    let _ = std::fs::remove_dir_all(dest);
    std::fs::rename(&incoming, dest)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_versions_numerically() {
        assert!(newer("2025.10", Some("2025.2")));
        assert!(!newer("2025.2", Some("2025.2")));
        assert!(newer("2024.1", None));
    }

    #[test]
    fn a_missing_state_is_due_now() {
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            data_dir: dir.path().into(),
            ..Config::default()
        };
        assert_eq!(until_due(&config), Duration::ZERO);
        update_state(&config, "last_checked_at", &time::format(time::now())).unwrap();
        assert!(until_due(&config) > Duration::from_secs(86_000));
    }
}

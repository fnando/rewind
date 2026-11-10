//! Runtime configuration, read from the environment (optionally seeded from a
//! dotenv file by the CLI).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct Config {
    pub data_dir: PathBuf,
    pub tmdb_api_key: Option<String>,
    pub fanart_api_key: Option<String>,
    pub session_secret: Option<String>,
    pub secret_key: Option<String>,
    pub host: String,
    pub port: u16,
    /// Seconds between background syncs.
    pub sync_interval: u64,
    /// How long a blocked SQLite writer waits before giving up (ms).
    pub db_busy_timeout: u64,
    pub allowed_hosts: Vec<String>,
    pub image_storage_dir: Option<PathBuf>,
    /// Base URLs of the external services. Overridable so tests can point
    /// them at a local mock server.
    pub tmdb_url: String,
    pub musicbrainz_url: String,
    pub coverart_url: String,
    pub fanart_url: String,
    pub tzdata_url: String,
}

fn var(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.trim().is_empty())
}

fn number<T: std::str::FromStr>(name: &str, default: T) -> T {
    var(name)
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

impl Default for Config {
    fn default() -> Self {
        Self {
            data_dir: PathBuf::from("data"),
            tmdb_api_key: None,
            fanart_api_key: None,
            session_secret: None,
            secret_key: None,
            host: "0.0.0.0".into(),
            port: 55_455,
            sync_interval: 60,
            db_busy_timeout: 15_000,
            allowed_hosts: Vec::new(),
            image_storage_dir: None,
            tmdb_url: "https://api.themoviedb.org/3".into(),
            musicbrainz_url: "https://musicbrainz.org/ws/2".into(),
            coverart_url: "https://coverartarchive.org".into(),
            fanart_url: "https://webservice.fanart.tv/v3.2".into(),
            tzdata_url: "https://pypi.org/pypi/tzdata/json".into(),
        }
    }
}

impl Config {
    #[must_use]
    pub fn from_env() -> Self {
        let defaults = Self::default();
        let data_dir = var("REWIND_DATA_DIR").map_or_else(
            || env::current_dir().unwrap_or_default().join("data"),
            PathBuf::from,
        );

        Self {
            data_dir,
            tmdb_api_key: var("TMDB_API_KEY"),
            fanart_api_key: var("FANART_API_KEY"),
            session_secret: var("REWIND_SESSION_SECRET"),
            secret_key: var("REWIND_SECRET_KEY"),
            host: var("REWIND_HOST").unwrap_or(defaults.host),
            port: number("REWIND_PORT", defaults.port),
            sync_interval: number("REWIND_SYNC_INTERVAL", defaults.sync_interval),
            db_busy_timeout: number("REWIND_DB_BUSY_TIMEOUT", defaults.db_busy_timeout),
            allowed_hosts: var("REWIND_ALLOWED_HOSTS")
                .map(|v| {
                    v.split(',')
                        .map(str::trim)
                        .filter(|h| !h.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default(),
            image_storage_dir: var("REWIND_IMAGE_STORAGE_DIR").map(PathBuf::from),
            ..defaults
        }
    }

    #[must_use]
    pub fn db_path(&self) -> PathBuf {
        self.data_dir.join("rewind.db")
    }

    #[must_use]
    pub fn image_storage_dir(&self) -> PathBuf {
        self.image_storage_dir
            .clone()
            .unwrap_or_else(|| self.data_dir.join("images"))
    }

    #[must_use]
    pub fn avatars_dir(&self) -> PathBuf {
        self.data_dir.join("avatars")
    }

    #[must_use]
    pub fn avatar_path(&self, user_id: i64) -> PathBuf {
        self.avatars_dir().join(format!("{user_id}.jpg"))
    }

    #[must_use]
    pub fn tzdata_dir(&self) -> PathBuf {
        self.data_dir.join("tzdata")
    }

    /// The secret that signs session cookies: `REWIND_SESSION_SECRET`, or one
    /// generated once and kept in the data dir.
    ///
    /// # Errors
    /// When the generated secret can't be written.
    pub fn resolved_session_secret(&self) -> Result<Vec<u8>> {
        if let Some(secret) = &self.session_secret {
            return Ok(secret.as_bytes().to_vec());
        }
        let hex = read_or_create_secret(&self.data_dir.join(".session_secret"), 64)?;
        Ok(hex.into_bytes())
    }

    /// The 32-byte key that encrypts stored Jellyfin tokens:
    /// `REWIND_SECRET_KEY` (base64), or one generated once in the data dir.
    ///
    /// # Errors
    /// When the key is malformed or the generated one can't be written.
    pub fn resolved_secret_key(&self) -> Result<[u8; 32]> {
        let encoded = if let Some(value) = &self.secret_key {
            value.trim().to_string()
        } else {
            let path = self.data_dir.join(".secret_key");
            if path.exists() {
                fs::read_to_string(&path)?.trim().to_string()
            } else {
                let key: [u8; 32] = rand::random();
                let encoded = crate::crypto::encode(&key);
                write_secret(&path, &encoded)?;
                encoded
            }
        };
        let bytes = crate::crypto::decode(&encoded).context("REWIND_SECRET_KEY must be base64")?;
        bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("REWIND_SECRET_KEY must decode to 32 bytes"))
    }

    /// The resolved settings, for `rewind config`. Secrets are redacted.
    #[must_use]
    pub fn summary(&self) -> Vec<(&'static str, String)> {
        let redact = |value: &Option<String>| {
            if value.is_some() {
                "[redacted]"
            } else {
                "(unset)"
            }
            .to_string()
        };
        vec![
            ("data_dir", self.data_dir.display().to_string()),
            ("db_path", self.db_path().display().to_string()),
            ("host", self.host.clone()),
            ("port", self.port.to_string()),
            ("tmdb_api_key", redact(&self.tmdb_api_key)),
            ("fanart_api_key", redact(&self.fanart_api_key)),
            ("session_secret", redact(&self.session_secret)),
            ("secret_key", redact(&self.secret_key)),
            ("sync_interval", self.sync_interval.to_string()),
            ("db_busy_timeout", self.db_busy_timeout.to_string()),
        ]
    }
}

fn read_or_create_secret(path: &Path, bytes: usize) -> Result<String> {
    if path.exists() {
        return Ok(fs::read_to_string(path)?.trim().to_string());
    }
    let random: Vec<u8> = (0..bytes).map(|_| rand::random::<u8>()).collect();
    let secret = hex::encode(random);
    write_secret(path, &secret)?;
    Ok(secret)
}

fn write_secret(path: &Path, value: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, value).with_context(|| format!("writing {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

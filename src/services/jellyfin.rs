//! Client for a Jellyfin server and its Rewind plugin.
//!
//! - `rewind_info` (public) confirms the plugin is installed before linking.
//! - `authenticate` exchanges a username and password for an access token.
//! - `rewind_changes` pages through the plugin's play history feed.
//! - `library_item` and friends read item metadata for the resolver.

use serde_json::{Map, Value, json};

use super::http::{self, Response};

/// The Rewind Jellyfin plugin's id, as reported by `/Rewind/Info`.
pub const PLUGIN_ID: &str = "6bcfddb4-c3fb-48f6-996f-5b02d07e3e62";
pub const PLUGIN_URL: &str = "https://github.com/fnando/jellyfin-rewind-plugin";
pub const CHANGES_LIMIT: u32 = 1000;
const ITEM_FIELDS: &str = "ProviderIds,ParentIndexNumber,IndexNumber,SeriesId,ParentId,\
     DateCreated,PremiereDate,ProductionYear,Genres,Path,Artists,AlbumArtists,Etag";

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    PluginMissing(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;

/// What signing in returns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Auth {
    pub access_token: String,
    pub user_id: String,
    pub user_name: Option<String>,
    pub server_id: Option<String>,
}

/// The `AudioMetadata` plugin's view of an album's file tags.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AlbumMetadata {
    pub release_type: Option<String>,
    pub release: Option<String>,
    pub artist: Option<String>,
    pub artist_name: Option<String>,
    pub tracks: Vec<AlbumTrack>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlbumTrack {
    pub item_id: String,
    pub release_track: String,
    pub recording: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Client {
    url: String,
    token: Option<String>,
    device_id: String,
}

#[must_use]
pub fn normalize_url(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

fn transport(error: &anyhow::Error) -> Error {
    Error::Other(format!("Jellyfin request failed: {error}"))
}

impl Client {
    #[must_use]
    pub fn new(url: &str, token: Option<String>) -> Self {
        Self {
            url: normalize_url(url),
            token,
            device_id: hex::encode(rand::random::<[u8; 16]>()),
        }
    }

    fn token_header(&self) -> String {
        format!(
            "MediaBrowser Token=\"{}\"",
            self.token.as_deref().unwrap_or_default()
        )
    }

    fn client_header(&self) -> String {
        format!(
            "MediaBrowser Client=\"Rewind\", Device=\"Rewind\", DeviceId=\"{}\", Version=\"{}\"",
            self.device_id,
            env!("CARGO_PKG_VERSION")
        )
    }

    fn authed(&self, path: &str) -> http::Request {
        http::get(format!("{}{path}", self.url)).header("Authorization", self.token_header())
    }

    /// The response when it succeeded; `Auth` on 401, `Other` on anything
    /// else.
    fn check(response: Response) -> Result<Response> {
        match response.status {
            200..=299 => Ok(response),
            401 => Err(Error::Auth("Jellyfin request unauthorized".into())),
            status => Err(Error::Other(format!("Jellyfin request failed: {status}"))),
        }
    }

    fn get_json(request: http::Request) -> Result<Value> {
        let response = Self::check(request.send().map_err(|e| transport(&e))?)?;
        response
            .json()
            .map_err(|_| Error::Other("Jellyfin response isn't JSON".into()))
    }

    /// Users listed on the server's sign-in screen, as `(id, name)`.
    #[must_use]
    pub fn public_users(&self) -> Vec<(String, String)> {
        if self.url.is_empty() {
            return Vec::new();
        }
        let Ok(response) = http::get(format!("{}/Users/Public", self.url)).send() else {
            return Vec::new();
        };
        if !response.ok() {
            return Vec::new();
        }
        response
            .json::<Vec<Value>>()
            .unwrap_or_default()
            .iter()
            .filter_map(|user| {
                Some((
                    user.get("Id")?.as_str()?.to_string(),
                    user.get("Name")?.as_str()?.to_string(),
                ))
            })
            .collect()
    }

    /// Exchanges credentials for an access token and the Jellyfin user id.
    pub fn authenticate(&self, username: &str, password: &str) -> Result<Auth> {
        let response = http::post(format!("{}/Users/AuthenticateByName", self.url))
            .header("Authorization", self.client_header())
            .json(json!({"Username": username, "Pw": password}))
            .send()
            .map_err(|e| Error::Auth(format!("Jellyfin authentication failed: {e}")))?;
        if !response.ok() {
            let body = response.excerpt(200);
            let suffix = if body.is_empty() {
                String::new()
            } else {
                format!(": {body}")
            };
            return Err(Error::Auth(format!(
                "Jellyfin authentication failed (HTTP {}){suffix}",
                response.status
            )));
        }
        let data: Value = response
            .json()
            .map_err(|_| Error::Auth("Jellyfin authentication failed: not JSON".into()))?;
        let text = |v: Option<&Value>| v.and_then(Value::as_str).map(String::from);
        Ok(Auth {
            access_token: text(data.get("AccessToken")).unwrap_or_default(),
            user_id: text(data.pointer("/User/Id")).unwrap_or_default(),
            user_name: text(data.pointer("/User/Name")),
            server_id: text(data.get("ServerId")),
        })
    }

    /// The username the token signs in as, or `None` when it can't be read.
    #[must_use]
    pub fn current_user_name(&self) -> Option<String> {
        let data = Self::get_json(self.authed("/Users/Me")).ok()?;
        presence(data.get("Name"))
    }

    /// The server's own id, from its public info. `None` when unreachable.
    #[must_use]
    pub fn server_id(&self) -> Option<String> {
        let response = http::get(format!("{}/System/Info/Public", self.url))
            .send()
            .ok()?;
        if !response.ok() {
            return None;
        }
        presence(response.json::<Value>().ok()?.get("Id"))
    }

    /// The Rewind plugin's public info, confirming the server has it. No
    /// sign-in needed.
    pub fn rewind_info(&self) -> Result<Value> {
        let response = http::get(format!("{}/Rewind/Info", self.url))
            .send()
            .map_err(|e| transport(&e))?;
        if response.status == 404 {
            return Err(Error::PluginMissing(
                "Rewind plugin not installed on this Jellyfin server (/Rewind/Info: 404)".into(),
            ));
        }
        let response = Self::check(response)?;
        let info: Option<Value> = response.json().ok();
        match info {
            Some(info)
                if info
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(is_plugin_id) =>
            {
                Ok(info)
            }
            _ => Err(Error::PluginMissing(format!(
                "/Rewind/Info isn't the Rewind plugin: {}",
                response.excerpt(200)
            ))),
        }
    }

    /// One page of the plugin's changes feed for the token's user: every play
    /// created or changed after `since`, in change order.
    pub fn rewind_changes(&self, since: i64, limit: u32) -> Result<Value> {
        let response = self
            .authed("/Rewind/History/Changes")
            .query("since", &since)
            .query("limit", &limit)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .map_err(|e| transport(&e))?;
        if response.status == 404 {
            return Err(Error::PluginMissing(
                "Rewind plugin not installed on this Jellyfin server".into(),
            ));
        }
        let response = Self::check(response)?;
        let page: Value = response
            .json()
            .map_err(|_| Error::Other("Rewind changes response isn't JSON".into()))?;
        // A page that isn't the feed's shape must fail loudly: read as "no
        // changes", it would silently import nothing.
        if !page.get("items").is_some_and(Value::is_array) || page.get("nextSince").is_none() {
            return Err(Error::Other(format!(
                "Unexpected Rewind changes response: {}",
                response.excerpt(200)
            )));
        }
        Ok(page)
    }

    /// A library item with every field the resolver reads. `None` when the
    /// server no longer has it (404); any other failure is an error, so an
    /// outage is never mistaken for a deleted item.
    pub fn library_item(&self, user_id: &str, item_id: &str) -> Result<Option<Value>> {
        let response = self
            .authed(&format!("/Users/{user_id}/Items/{item_id}"))
            .query("Fields", &ITEM_FIELDS)
            .send()
            .map_err(|e| transport(&e))?;
        if response.status == 404 {
            return Ok(None);
        }
        let response = Self::check(response)?;
        response
            .json()
            .map(Some)
            .map_err(|_| Error::Other("Jellyfin response isn't JSON".into()))
    }

    /// An item's `ProviderIds`; empty on failure.
    #[must_use]
    pub fn provider_ids(&self, user_id: &str, item_id: &str) -> Map<String, Value> {
        Self::get_json(
            self.authed(&format!("/Users/{user_id}/Items/{item_id}"))
                .query("Fields", "ProviderIds"),
        )
        .ok()
        .and_then(|item| item.get("ProviderIds").and_then(Value::as_object).cloned())
        .unwrap_or_default()
    }

    /// A single item (Name, Type, `ImageTags`); empty on failure.
    #[must_use]
    pub fn item(&self, user_id: &str, item_id: &str) -> Value {
        Self::get_json(self.authed(&format!("/Users/{user_id}/Items/{item_id}")))
            .unwrap_or_else(|_| json!({}))
    }

    /// Whether an item still exists: `Some(true)`, `Some(false)` on 404, and
    /// `None` when it can't be told, so an outage is never read as deleted.
    #[must_use]
    pub fn item_present(&self, user_id: &str, item_id: &str) -> Option<bool> {
        let response = self
            .authed(&format!("/Users/{user_id}/Items/{item_id}"))
            .send()
            .ok()?;
        match response.status {
            200..=299 => Some(true),
            404 => Some(false),
            _ => None,
        }
    }

    /// Every track on an album, in disc and track order; empty on failure.
    #[must_use]
    pub fn album_tracks(&self, user_id: &str, album_id: &str) -> Vec<Value> {
        Self::items(
            self.authed(&format!("/Users/{user_id}/Items"))
                .query("ParentId", &album_id)
                .query("IncludeItemTypes", &"Audio")
                .query("Recursive", &"true")
                .query("SortBy", &"ParentIndexNumber,IndexNumber,SortName")
                .query("SortOrder", &"Ascending")
                .query(
                    "Fields",
                    "ProviderIds,ParentIndexNumber,IndexNumber,RunTimeTicks,PremiereDate,\
                     ProductionYear,Genres,AlbumArtists,Etag",
                )
                .query("Limit", &500),
        )
    }

    /// Every album credited to an artist; empty on failure.
    #[must_use]
    pub fn artist_albums(&self, user_id: &str, artist_id: &str) -> Vec<Value> {
        Self::items(
            self.authed(&format!("/Users/{user_id}/Items"))
                .query("AlbumArtistIds", &artist_id)
                .query("IncludeItemTypes", &"MusicAlbum")
                .query("Recursive", &"true")
                .query("SortBy", &"PremiereDate,ProductionYear,SortName")
                .query("SortOrder", &"Descending")
                .query(
                    "Fields",
                    "ProviderIds,PremiereDate,ProductionYear,Genres,AlbumArtists,Etag",
                )
                .query("Limit", &500),
        )
    }

    fn items(request: http::Request) -> Vec<Value> {
        Self::get_json(request)
            .ok()
            .and_then(|data| data.get("Items").and_then(Value::as_array).cloned())
            .unwrap_or_default()
    }

    /// The album's release type and MusicBrainz ids, read from its file tags
    /// by the `AudioMetadata` plugin. Empty when the plugin is absent, the
    /// album is untagged, or the lookup fails.
    #[must_use]
    pub fn album_metadata(&self, album_id: &str) -> AlbumMetadata {
        let Ok(data) = Self::get_json(self.authed(&format!("/AudioMetadata/Album/{album_id}")))
        else {
            return AlbumMetadata::default();
        };
        let tracks: Vec<Value> = data
            .get("Tracks")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let raw = |key: &str| -> Vec<Option<&Value>> {
            tracks
                .iter()
                .map(|t| t.get("RawTags").and_then(|r| r.get(key)))
                .collect()
        };
        let field =
            |key: &str| -> Vec<Option<&Value>> { tracks.iter().map(|t| t.get(key)).collect() };

        let mut release_values = field("MusicBrainzAlbumId");
        release_values.extend(raw("MUSICBRAINZ_ALBUMID"));
        let mut name_values = raw("ALBUMARTISTS");
        name_values.extend(raw("ALBUMARTIST"));
        name_values.extend(raw("ARTIST"));

        AlbumMetadata {
            release_type: first_tag(&field("ReleaseType")).map(|t| t.to_lowercase()),
            release: first_mbid(&release_values),
            artist: first_mbid(&raw("MUSICBRAINZ_ALBUMARTISTID")),
            artist_name: first_tag(&name_values)
                .and_then(|n| n.split(';').next().map(|s| s.trim().to_string())),
            tracks: tracks.iter().filter_map(album_track_entry).collect(),
        }
    }
}

fn presence(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Jellyfin writes GUIDs without dashes, so compare the bare hex.
fn is_plugin_id(value: &str) -> bool {
    let normalize = |id: &str| id.replace('-', "").to_lowercase();
    normalize(value) == normalize(PLUGIN_ID)
}

fn first_tag(values: &[Option<&Value>]) -> Option<String> {
    values.iter().find_map(|v| presence(*v))
}

/// A tag can hold several mbids joined by ';' or '/'; take the first.
fn first_mbid(values: &[Option<&Value>]) -> Option<String> {
    first_tag(values).and_then(|raw| {
        raw.split([';', '/'])
            .next()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    })
}

fn album_track_entry(track: &Value) -> Option<AlbumTrack> {
    let item_id = presence(track.get("ItemId"))?;
    let raw = track.get("RawTags");
    let release_track = first_mbid(&[raw.and_then(|r| r.get("MUSICBRAINZ_RELEASETRACKID"))])?;
    let recording = first_mbid(&[
        track.get("MusicBrainzTrackId"),
        raw.and_then(|r| r.get("MUSICBRAINZ_TRACKID")),
    ]);
    Some(AlbumTrack {
        item_id,
        release_track,
        recording,
    })
}

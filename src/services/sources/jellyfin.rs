//! Resolves the Jellyfin items in a user's play history into Rewind items,
//! via TMDB (movies, episodes), MusicBrainz ids (music) or Jellyfin's own
//! metadata (music videos and loose videos).

use std::collections::{HashMap, HashSet};

use anyhow::Result;
use rusqlite::Connection;
use serde_json::{Map, Value, json};

use crate::config::Config;
use crate::models::Source;
use crate::models::item::{Attrs, Item};
use crate::services::jellyfin::{self, AlbumMetadata, Client};
use crate::services::musicbrainz::{AlbumInput, MusicBrainz, TrackInput};
use crate::services::tmdb::Tmdb;
use crate::services::{jellyfin_archive, music_video};

/// Types that are a library, not a content folder.
const LIBRARY_ROOT_TYPES: &[&str] = &["CollectionFolder", "UserRootFolder", "AggregateFolder"];

pub struct Adapter {
    client: Client,
    source: Source,
    tmdb: Tmdb,
    musicbrainz: MusicBrainz,
    series_tmdb: HashMap<String, Option<i64>>,
    folders: HashMap<String, Option<Value>>,
    albums_backfilled: HashSet<String>,
    artists_backfilled: HashSet<String>,
    album_meta: HashMap<String, AlbumMetadata>,
}

fn text<'v>(value: &'v Value, key: &str) -> Option<&'v str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn presence(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|s| !s.is_empty())
}

/// A positive integer from a JSON number or numeric string.
fn positive_int(value: Option<&Value>) -> Option<i64> {
    let n = match value? {
        Value::Number(n) => n.as_i64()?,
        Value::String(s) => s.trim().parse().ok()?,
        _ => return None,
    };
    (n > 0).then_some(n)
}

fn first_name(value: Option<&Value>) -> Option<&str> {
    match value?.as_array()?.first()? {
        Value::String(s) => presence(Some(s)),
        Value::Object(map) => presence(map.get("Name").and_then(Value::as_str)),
        _ => None,
    }
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

/// The first id of a possibly multi-artist credit ("a; b" or "a/b").
fn first_id(value: Option<&str>) -> Option<String> {
    presence(value)?
        .split([';', '/'])
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

fn clean_imdb(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    let digits = value.strip_prefix("tt")?;
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| value.to_string())
}

fn premiere_date(item: &Value) -> Option<String> {
    if let Some(premiere) = text(item, "PremiereDate") {
        return Some(premiere.chars().take(10).collect());
    }
    positive_int(item.get("ProductionYear")).map(|year| format!("{year}-01-01"))
}

#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn ticks_to_minutes(ticks: Option<&Value>) -> Option<i64> {
    let ticks = ticks?.as_i64()?;
    let minutes = (ticks as f64 / 600_000_000.0).round() as i64;
    (minutes > 0).then_some(minutes)
}

/// A host-less Jellyfin image reference; the host is added at serve time.
fn primary_image_url(item_id: Option<&str>, tag: Option<&str>) -> Option<String> {
    Some(format!("/Items/{}/Images/Primary?tag={}", item_id?, tag?))
}

fn primary_image(item: &Value) -> Option<String> {
    primary_image_url(
        text(item, "Id"),
        item.pointer("/ImageTags/Primary").and_then(Value::as_str),
    )
}

/// Prefers the stable YouTube id (survives re-imports) over Jellyfin's.
fn generic_external_id(item: &Value) -> String {
    match item
        .pointer("/ProviderIds/youtube")
        .and_then(Value::as_str)
        .and_then(|s| presence(Some(s)))
    {
        Some(yt) => format!("youtube:{yt}"),
        None => format!("jellyfin:{}", text(item, "Id").unwrap_or_default()),
    }
}

fn describe(item: &Value) -> String {
    format!(
        "{} {:?} ({})",
        text(item, "Type").unwrap_or_default(),
        text(item, "Name").unwrap_or_default(),
        text(item, "Id").unwrap_or_default()
    )
}

fn log_skip(item: &Value, reason: &str) -> Option<Item> {
    tracing::info!("[sync/jellyfin] skipped {} — {reason}", describe(item));
    None
}

/// True when an error came from the database, which must propagate (a lock
/// defers the entry) rather than be read as "no match".
fn is_db_error(error: &anyhow::Error) -> bool {
    error
        .chain()
        .any(|e| e.downcast_ref::<rusqlite::Error>().is_some())
}

/// The plugin's snapshot of an item, taken when it played, in the shape of a
/// Jellyfin API item, so an item the library no longer has still resolves.
/// No Etag, so it's never mistaken for an unchanged item.
#[must_use]
pub fn snapshot_item(entry: &Value) -> Value {
    let mut item = Map::new();
    let mut put = |key: &str, value: Option<&Value>| {
        if let Some(value) = value.filter(|v| !v.is_null()) {
            item.insert(key.into(), value.clone());
        }
    };
    put("Id", entry.get("itemId"));
    put("Type", entry.get("itemType"));
    put("Name", entry.get("name"));
    put(
        "ProviderIds",
        Some(entry.get("providerIds").unwrap_or(&json!({}))),
    );
    put("IndexNumber", entry.get("indexNumber"));
    put(
        "ParentIndexNumber",
        entry
            .get("seasonNumber")
            .filter(|v| !v.is_null())
            .or_else(|| entry.get("discNumber")),
    );
    put("SeriesId", entry.get("seriesId"));
    put("SeriesName", entry.get("seriesName"));
    put("SeriesProviderIds", entry.get("seriesProviderIds"));
    put("ParentId", entry.get("albumId"));
    put("AlbumId", entry.get("albumId"));
    put("Album", entry.get("album"));
    put("Artists", entry.get("artists"));
    let album_artists = entry
        .get("albumArtists")
        .and_then(Value::as_array)
        .map(|names| Value::Array(names.iter().map(|name| json!({"Name": name})).collect()));
    put("AlbumArtists", album_artists.as_ref());
    put("ProductionYear", entry.get("productionYear"));
    put("Genres", entry.get("genres"));
    put("RunTimeTicks", entry.get("runtimeTicks"));
    Value::Object(item)
}

impl Adapter {
    #[must_use]
    pub fn new(config: &Config, source: Source, access_token: String) -> Self {
        Self {
            client: Client::new(&source.url, Some(access_token)),
            source,
            tmdb: Tmdb::new(config),
            musicbrainz: MusicBrainz::new(config),
            series_tmdb: HashMap::new(),
            folders: HashMap::new(),
            albums_backfilled: HashSet::new(),
            artists_backfilled: HashSet::new(),
            album_meta: HashMap::new(),
        }
    }

    #[must_use]
    pub fn client(&self) -> &Client {
        &self.client
    }

    fn user_id(&self) -> &str {
        &self.source.external_user_id
    }

    /// One page of the plugin's changes feed after `since`.
    pub fn changes(&self, since: i64) -> jellyfin::Result<Value> {
        self.client.rewind_changes(since, jellyfin::CHANGES_LIMIT)
    }

    /// The item a feed entry played, or `None` when it can't be matched.
    /// Reads the live library item; when the server no longer has it, falls
    /// back to the item already stamped with its Jellyfin id, then to the
    /// plugin's snapshot. Transport errors propagate so the entry is retried
    /// instead of resolved from a stale snapshot.
    pub fn resolve_entry(&mut self, conn: &Connection, entry: &Value) -> Result<Option<Item>> {
        let Some(item_id) = text(entry, "itemId") else {
            return Ok(log_skip(&snapshot_item(entry), "no item id"));
        };
        let live = self.client.library_item(self.user_id(), item_id)?;
        if live.is_none()
            && let Some(known) = Item::find_by_jellyfin_id(conn, item_id)?
        {
            return Ok(Some(known));
        }
        let item = live.unwrap_or_else(|| snapshot_item(entry));
        self.resolve_played(conn, &item)
    }

    fn resolve_played(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        tracing::debug!("[sync/jellyfin] {} fields: {item}", describe(item));
        let resolved = match self.resolve(conn, item) {
            Ok(Some(resolved)) => resolved,
            Ok(None) => return Ok(log_skip(item, "no TMDB/MusicBrainz match")),
            Err(error) if is_db_error(&error) => return Err(error),
            Err(error) => return Ok(log_skip(item, &format!("{error:#}"))),
        };
        // Stamp the stable Jellyfin id so ratings key off it. Audio gets it
        // through MusicBrainz (so album siblings do too).
        let audio = text(item, "Type") == Some("Audio");
        let mut resolved = resolved;
        if !audio
            && let Some(id) = text(item, "Id")
            && resolved.jellyfin_id.as_deref() != Some(id)
        {
            Item::update(
                conn,
                resolved.id,
                &Attrs::new().text("jellyfin_id", Some(id)),
            )?;
            resolved.jellyfin_id = Some(id.to_string());
        }
        if !audio {
            jellyfin_archive::remember(
                conn,
                &resolved,
                text(item, "Id"),
                &resolved.media_type,
                &self.instance_for(item),
                None,
            )?;
        }
        Ok(Some(resolved))
    }

    fn instance_for(&self, item: &Value) -> String {
        text(item, "ServerId").map_or_else(|| self.source.instance_id.clone(), String::from)
    }

    /// Matches through TMDB/MusicBrainz, falling back to Jellyfin's own
    /// metadata. Short-circuits when the item's Etag is unchanged.
    pub fn resolve(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        if let Some(unchanged) = unchanged_item(conn, item)? {
            return Ok(Some(unchanged));
        }
        let resolved = match text(item, "Type") {
            Some("Movie") => match self.try_match(conn, item, Self::resolve_movie)? {
                Some(movie) => Some(movie),
                None => generic_video(conn, item, "movie")?,
            },
            Some("Episode") => match self.try_match(conn, item, Self::resolve_episode)? {
                Some(episode) => Some(episode),
                None => match generic_episode(conn, item)? {
                    Some(episode) => Some(episode),
                    None => generic_video(conn, item, "movie")?,
                },
            },
            Some("Audio") => self.resolve_audio(conn, item)?,
            Some("MusicVideo") => music_video_item(conn, item)?,
            Some("Video") => match self.generic_folder_episode(conn, item)? {
                Some(episode) => Some(episode),
                None => generic_video(conn, item, "movie")?,
            },
            _ => None,
        };
        if let Some(resolved) = &resolved {
            stamp_source_etag(conn, resolved, item)?;
        }
        Ok(resolved)
    }

    /// Runs a match but swallows lookup errors, so a flaky match still falls
    /// through to the Jellyfin-native fallback. Database errors propagate.
    fn try_match(
        &mut self,
        conn: &Connection,
        item: &Value,
        matcher: fn(&mut Self, &Connection, &Value) -> Result<Option<Item>>,
    ) -> Result<Option<Item>> {
        match matcher(self, conn, item) {
            Ok(found) => Ok(found),
            Err(error) if is_db_error(&error) => Err(error),
            Err(error) => {
                tracing::info!("[sync/jellyfin] match failed: {error:#}");
                Ok(None)
            }
        }
    }

    fn resolve_movie(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let ids = item.get("ProviderIds");
        let tmdb = match positive_int(ids.and_then(|i| i.get("Tmdb"))) {
            Some(id) => Some(id),
            None => self.lookup_tmdb_by_imdb(
                clean_imdb(ids.and_then(|i| i.get("Imdb")).and_then(Value::as_str)).as_deref(),
                "movie_results",
            ),
        };
        let Some(tmdb) = tmdb else { return Ok(None) };
        Ok(Some(self.tmdb.movie(conn, tmdb)?))
    }

    fn resolve_episode(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let season = positive_int(item.get("ParentIndexNumber"));
        let episode = positive_int(item.get("IndexNumber"));
        let series = self.series_tmdb_id(item);
        let (Some(series), Some(season), Some(episode)) = (series, season, episode) else {
            return Ok(None);
        };
        Ok(Some(self.tmdb.episode(conn, series, season, episode)?))
    }

    /// The series' TMDB id: from the snapshot's series ids, else the series'
    /// provider ids (once per series), falling back to IMDB lookups.
    fn series_tmdb_id(&mut self, item: &Value) -> Option<i64> {
        let series_id = text(item, "SeriesId").unwrap_or_default().to_string();
        if let Some(cached) = self.series_tmdb.get(&series_id) {
            return *cached;
        }
        let ids: Map<String, Value> =
            if let Some(ids) = item.get("SeriesProviderIds").and_then(Value::as_object) {
                ids.clone()
            } else if series_id.is_empty() {
                Map::new()
            } else {
                self.client.provider_ids(self.user_id(), &series_id)
            };
        let episode_imdb = clean_imdb(item.pointer("/ProviderIds/Imdb").and_then(Value::as_str));
        let found = positive_int(ids.get("Tmdb"))
            .or_else(|| {
                self.lookup_tmdb_by_imdb(
                    clean_imdb(ids.get("Imdb").and_then(Value::as_str)).as_deref(),
                    "tv_results",
                )
            })
            .or_else(|| {
                let imdb = episode_imdb?;
                let found = self.tmdb.find_by_imdb(&imdb).ok()?;
                found
                    .pointer("/tv_episode_results/0/show_id")
                    .and_then(Value::as_i64)
            });
        self.series_tmdb.insert(series_id, found);
        found
    }

    fn lookup_tmdb_by_imdb(&self, imdb: Option<&str>, key: &str) -> Option<i64> {
        let found = self.tmdb.find_by_imdb(imdb?).ok()?;
        found.get(key)?.as_array()?.first()?.get("id")?.as_i64()
    }

    fn resolve_audio(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let Some(track) = self.music_item(conn, item)? else {
            return Ok(None);
        };
        self.backfill_album_tracks(conn, text(item, "ParentId"))?;
        self.backfill_artist_albums(conn, item)?;
        Ok(Some(track))
    }

    /// Jellyfin Audio → track item, shared by played tracks and their album
    /// siblings. Skips the re-resolve when the Etag is unchanged.
    fn music_item(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let track = match unchanged_item(conn, item)? {
            Some(track) => Some(track),
            None => self.resolve_music_track(conn, item)?,
        };
        let Some(track) = track else { return Ok(None) };
        self.archive_track(conn, &track, item)?;
        Ok(Some(track))
    }

    fn resolve_music_track(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let Some(title) = text(item, "Name") else {
            return Ok(None);
        };
        let ids = item
            .get("ProviderIds")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let album_id = text(item, "ParentId");
        let (release, artist_mbid) = self.album_mbids(&ids, album_id);
        let release_track = match text(&ids, "MusicBrainzTrack") {
            Some(rt) => Some(rt.to_string()),
            None => self
                .plugin_track(album_id, text(item, "Id"))
                .map(|t| t.release_track),
        };
        let artist = self.album_artist_name(item, album_id);
        let release_date = premiere_date(item);
        let track = self.musicbrainz.resolve(
            conn,
            &TrackInput {
                title,
                artist: artist.as_deref(),
                album: text(item, "Album"),
                release_track_mbid: release_track.as_deref(),
                release_mbid: release.as_deref(),
                artist_mbid: artist_mbid.as_deref(),
                length_ms: Some(
                    item.get("RunTimeTicks")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        / 10_000,
                ),
                track_number: positive_int(item.get("IndexNumber")),
                disc_number: positive_int(item.get("ParentIndexNumber")),
                release_date: release_date.as_deref(),
                genres: string_list(item.get("Genres")),
                jellyfin_id: text(item, "Id"),
                album_jellyfin_id: album_id,
            },
        )?;
        if let Some(track) = &track {
            stamp_source_etag(conn, track, item)?;
        }
        Ok(track)
    }

    /// Logs the track's id → item + recording, and on the id's first sighting
    /// runs the re-tag healer.
    fn archive_track(&mut self, conn: &Connection, track: &Item, item: &Value) -> Result<()> {
        let Some(jellyfin_id) = text(item, "Id") else {
            return Ok(());
        };
        let instance = self.instance_for(item);
        let mut recording = item
            .pointer("/ProviderIds/MusicBrainzRecording")
            .and_then(Value::as_str)
            .and_then(|r| presence(Some(r)))
            .map(String::from);
        if jellyfin_archive::seen(conn, Some(jellyfin_id), &instance)? {
            return jellyfin_archive::remember(
                conn,
                track,
                Some(jellyfin_id),
                "track",
                &instance,
                recording.as_deref(),
            );
        }
        if recording.is_none() {
            recording = self
                .plugin_track(text(item, "ParentId"), Some(jellyfin_id))
                .and_then(|t| t.recording);
        }
        let client = self.client.clone();
        let user_id = self.user_id().to_string();
        jellyfin_archive::reconcile(conn, track, recording.as_deref(), &instance, &|id| {
            client.item_present(&user_id, id)
        });
        jellyfin_archive::remember(
            conn,
            track,
            Some(jellyfin_id),
            "track",
            &instance,
            recording.as_deref(),
        )
    }

    /// Resolves every track on an album so its full tracklist exists. Once
    /// per album per run; re-fetched next run to pick up new tracks.
    fn backfill_album_tracks(&mut self, conn: &Connection, album_id: Option<&str>) -> Result<()> {
        let Some(album_id) = album_id else {
            return Ok(());
        };
        if !self.albums_backfilled.insert(album_id.to_string()) {
            return Ok(());
        }
        for sibling in self
            .client
            .album_tracks(&self.source.external_user_id, album_id)
        {
            self.music_item(conn, &sibling)?;
        }
        Ok(())
    }

    /// Resolves every album the played track's artist is credited on, so the
    /// artist page shows the full discography. Once per artist per run.
    fn backfill_artist_albums(&mut self, conn: &Connection, item: &Value) -> Result<()> {
        let artist = item
            .pointer("/AlbumArtists/0")
            .or_else(|| item.pointer("/ArtistItems/0"));
        let Some(artist_id) = artist.and_then(|a| text(a, "Id")) else {
            return Ok(());
        };
        if !self.artists_backfilled.insert(artist_id.to_string()) {
            return Ok(());
        }
        for album in self
            .client
            .artist_albums(&self.source.external_user_id, artist_id)
        {
            self.music_album(conn, &album)?;
        }
        Ok(())
    }

    fn music_album(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let Some(title) = text(item, "Name") else {
            return Ok(None);
        };
        let ids = item
            .get("ProviderIds")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let album_id = text(item, "Id");
        let (release, artist_mbid) = self.album_mbids(&ids, album_id);
        let artist = self.album_artist_name(item, album_id);
        let release_date = premiere_date(item);
        let album = self.musicbrainz.resolve_album(
            conn,
            &AlbumInput {
                title,
                artist: artist.as_deref(),
                release_mbid: release.as_deref(),
                artist_mbid: artist_mbid.as_deref(),
                release_date: release_date.as_deref(),
                genres: string_list(item.get("Genres")),
                jellyfin_id: album_id,
            },
        )?;
        let Some(album) = album else { return Ok(None) };
        self.stamp_release_type(conn, &album, album_id)?;
        jellyfin_archive::remember(
            conn,
            &album,
            album_id,
            "album",
            &self.instance_for(item),
            None,
        )?;
        Ok(Some(album))
    }

    /// The release and album-artist mbids, from the item's own provider ids,
    /// else from the album's file tags via the `AudioMetadata` plugin.
    fn album_mbids(
        &mut self,
        ids: &Value,
        album_id: Option<&str>,
    ) -> (Option<String>, Option<String>) {
        let mut release = first_id(text(ids, "MusicBrainzAlbum"));
        let mut artist = first_id(text(ids, "MusicBrainzAlbumArtist"))
            .or_else(|| first_id(text(ids, "MusicBrainzArtist")));
        if release.is_none() || artist.is_none() {
            let plugin = self.album_plugin_metadata(album_id);
            release = release.or_else(|| plugin.release.clone());
            artist = artist.or_else(|| plugin.artist.clone());
        }
        (release, artist)
    }

    fn plugin_track(
        &mut self,
        album_id: Option<&str>,
        jellyfin_id: Option<&str>,
    ) -> Option<jellyfin::AlbumTrack> {
        let jellyfin_id = jellyfin_id?;
        album_id?;
        self.album_plugin_metadata(album_id)
            .tracks
            .iter()
            .find(|t| t.item_id == jellyfin_id)
            .cloned()
    }

    /// Album tags from the `AudioMetadata` plugin, fetched once per album.
    fn album_plugin_metadata(&mut self, album_id: Option<&str>) -> AlbumMetadata {
        let Some(album_id) = album_id else {
            return AlbumMetadata::default();
        };
        if let Some(cached) = self.album_meta.get(album_id) {
            return cached.clone();
        }
        let meta = self.client.album_metadata(album_id);
        self.album_meta.insert(album_id.to_string(), meta.clone());
        meta
    }

    /// The lead album artist's name: the plugin's file tags first (they join
    /// a split credit with ";"), then Jellyfin's structured `AlbumArtists`,
    /// its flat `AlbumArtist`, and `Artists`.
    fn album_artist_name(&mut self, item: &Value, album_id: Option<&str>) -> Option<String> {
        self.album_plugin_metadata(album_id)
            .artist_name
            .filter(|n| !n.trim().is_empty())
            .or_else(|| first_name(item.get("AlbumArtists")).map(String::from))
            .or_else(|| text(item, "AlbumArtist").map(String::from))
            .or_else(|| first_name(item.get("Artists")).map(String::from))
    }

    /// Caches the album's release type the first time it's seen.
    fn stamp_release_type(
        &mut self,
        conn: &Connection,
        album: &Item,
        album_id: Option<&str>,
    ) -> Result<()> {
        if album.metadata.contains_key("release_type") {
            return Ok(());
        }
        let id = album_id
            .map(String::from)
            .or_else(|| album.jellyfin_id.clone());
        let Some(kind) = self.album_plugin_metadata(id.as_deref()).release_type else {
            return Ok(());
        };
        let mut metadata = album.metadata.clone();
        metadata.insert("release_type".into(), json!(kind));
        Item::update(
            conn,
            album.id,
            &Attrs::new().metadata(&Value::Object(metadata)),
        )
    }

    /// When a loose video sits in a nested folder, the folder is its series.
    fn generic_folder_episode(&mut self, conn: &Connection, item: &Value) -> Result<Option<Item>> {
        let Some(title) = text(item, "Name") else {
            return Ok(None);
        };
        let Some(folder) = self.parent_folder(item) else {
            return Ok(None);
        };
        let series = Item::upsert(
            conn,
            "series",
            &format!("jellyfin:{}", text(&folder, "Id").unwrap_or_default()),
            &Attrs::new()
                .text(
                    "title",
                    Some(text(&folder, "Name").unwrap_or("Unknown series")),
                )
                .text("poster_path", primary_image(&folder))
                .metadata(&json!({"series_name": text(&folder, "Name"), "source": "jellyfin"})),
        )?;
        Ok(Some(Item::upsert(
            conn,
            "episode",
            &generic_external_id(item),
            &Attrs::new()
                .text("parent_external_id", Some(series.external_id))
                .text("title", Some(title))
                .text("release_date", premiere_date(item))
                .int("runtime", ticks_to_minutes(item.get("RunTimeTicks")))
                .text("poster_path", primary_image(item))
                .metadata(&json!({"series_name": text(&folder, "Name"), "source": "jellyfin"})),
        )?))
    }

    /// The containing folder to treat as a series: not a library, nor the
    /// library's own top folder.
    fn parent_folder(&mut self, item: &Value) -> Option<Value> {
        let parent_id = text(item, "ParentId")?.to_string();
        if let Some(cached) = self.folders.get(&parent_id) {
            return cached.clone();
        }
        let folder = self.series_folder(&parent_id);
        self.folders.insert(parent_id, folder.clone());
        folder
    }

    fn series_folder(&self, folder_id: &str) -> Option<Value> {
        let folder = self.client.item(self.user_id(), folder_id);
        if text(&folder, "Type") != Some("Folder") {
            return None;
        }
        let grandparent = self.client.item(self.user_id(), text(&folder, "ParentId")?);
        if LIBRARY_ROOT_TYPES.contains(&text(&grandparent, "Type").unwrap_or_default()) {
            return None;
        }
        Some(folder)
    }
}

/// The stored item for this payload when its Etag is unchanged.
fn unchanged_item(conn: &Connection, item: &Value) -> Result<Option<Item>> {
    let (Some(id), Some(etag)) = (text(item, "Id"), text(item, "Etag")) else {
        return Ok(None);
    };
    Ok(Item::find_by_jellyfin_id(conn, id)?.filter(|e| e.source_etag.as_deref() == Some(etag)))
}

fn stamp_source_etag(conn: &Connection, resolved: &Item, item: &Value) -> Result<()> {
    match text(item, "Etag") {
        Some(etag) if resolved.source_etag.as_deref() != Some(etag) => Item::update(
            conn,
            resolved.id,
            &Attrs::new().text("source_etag", Some(etag)),
        ),
        _ => Ok(()),
    }
}

fn music_video_item(conn: &Connection, item: &Value) -> Result<Option<Item>> {
    let Some(title) = text(item, "Name") else {
        return Ok(None);
    };
    let artist = first_name(item.get("Artists"))
        .or_else(|| first_name(item.get("AlbumArtists")))
        .or_else(|| text(item, "AlbumArtist"))
        .map(String::from)
        .or_else(|| {
            let path = text(item, "Path")?;
            let parent = std::path::Path::new(path).parent()?.file_name()?.to_str()?;
            presence(Some(parent)).map(String::from)
        });
    let external_id = generic_external_id(item);
    let release_date = premiere_date(item);
    let poster = primary_image(item);
    Ok(Some(music_video::build(
        conn,
        &music_video::VideoInput {
            external_id: &external_id,
            title,
            artist_name: artist.as_deref(),
            runtime: ticks_to_minutes(item.get("RunTimeTicks")),
            release_date: release_date.as_deref(),
            poster_path: poster.as_deref(),
            jellyfin_id: text(item, "Id"),
        },
    )?))
}

fn generic_video(conn: &Connection, item: &Value, media_type: &str) -> Result<Option<Item>> {
    let Some(title) = text(item, "Name") else {
        return Ok(None);
    };
    Ok(Some(Item::upsert(
        conn,
        media_type,
        &generic_external_id(item),
        &Attrs::new()
            .text("title", Some(title))
            .text("release_date", premiere_date(item))
            .int("runtime", ticks_to_minutes(item.get("RunTimeTicks")))
            .text("poster_path", primary_image(item))
            .metadata(&json!({"source": "jellyfin"})),
    )?))
}

fn generic_episode(conn: &Connection, item: &Value) -> Result<Option<Item>> {
    let (Some(title), Some(series_id)) = (text(item, "Name"), text(item, "SeriesId")) else {
        return Ok(None);
    };
    let series_name = text(item, "SeriesName");
    let series = Item::upsert(
        conn,
        "series",
        &format!("jellyfin:{series_id}"),
        &Attrs::new()
            .text("title", Some(series_name.unwrap_or("Unknown series")))
            .text(
                "poster_path",
                primary_image_url(Some(series_id), text(item, "SeriesPrimaryImageTag")),
            )
            .metadata(&json!({"series_name": series_name, "source": "jellyfin"})),
    )?;
    Ok(Some(Item::upsert(
        conn,
        "episode",
        &generic_external_id(item),
        &Attrs::new()
            .text("parent_external_id", Some(series.external_id))
            .text("title", Some(title))
            .int("season_number", positive_int(item.get("ParentIndexNumber")))
            .int("episode_number", positive_int(item.get("IndexNumber")))
            .text("release_date", premiere_date(item))
            .int("runtime", ticks_to_minutes(item.get("RunTimeTicks")))
            .text("poster_path", primary_image(item))
            .metadata(&json!({"series_name": series_name, "source": "jellyfin"})),
    )?))
}

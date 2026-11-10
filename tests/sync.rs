mod common;

use common::{Env, KEY, entry, movie_item};
use rewind::cli::{self, SyncArgs};
use rewind::models::play::{NewPlay, Play};
use rewind::models::{ErrorLog, Item, Source, SourceError, UserItem};
use rewind::services::sources::jellyfin::Adapter;
use rewind::services::sync::{self, Outcome};
use serde_json::json;

struct Fixture {
    env: Env,
    user_id: i64,
    source: Source,
}

fn fixture() -> Fixture {
    let env = Env::new();
    let user = env.create_user("fnando");
    let source = env.create_source(user.id, "u-1", "srv-1");
    Fixture {
        env,
        user_id: user.id,
        source,
    }
}

impl Fixture {
    fn sync(&self) -> sync::Tally {
        sync::sync_source(&self.env.config, &self.env.conn, &KEY, &self.source).unwrap()
    }

    fn try_sync(&self) -> anyhow::Result<sync::Tally> {
        sync::sync_source(&self.env.config, &self.env.conn, &KEY, &self.source)
    }

    fn source(&self) -> Source {
        self.env.reload_source(self.source.id)
    }

    fn plays(&self) -> Vec<Play> {
        let mut stmt = self
            .env
            .conn
            .prepare(&format!(
                "SELECT {} FROM plays ORDER BY id",
                rewind::models::play::COLUMNS
            ))
            .unwrap();
        stmt.query_map([], Play::from_row)
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    fn movie(&mut self) {
        self.env.stub_tmdb_movie(27_205);
        self.env.stub_library_item(&movie_item("m1"));
    }
}

#[test]
fn records_a_scrobble_at_its_start_time_and_advances_the_cursor() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(&[vec![entry(7, &json!({}))]], 0);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    let plays = f.plays();
    assert_eq!(plays.len(), 1);
    let play = &plays[0];
    assert_eq!(play.source, "jellyfin");
    assert_eq!(play.source_id, Some(f.source.id));
    assert_eq!(play.instance_id.as_deref(), Some("srv-1"));
    assert_eq!(play.source_event_id.as_deref(), Some("rewind:p1"));
    assert_eq!(play.started_at, "2026-10-16T05:00:00.000000Z");
    let item = Item::find(&f.env.conn, play.item_id).unwrap().unwrap();
    assert_eq!(item.external_id, "tmdb:27205");
    assert_eq!(f.source().cursor.as_deref(), Some("7"));
    assert!(f.source().last_synced_at.is_some());
}

#[test]
fn stores_how_far_the_play_got_and_where_it_played() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[vec![entry(
            1,
            &json!({
                "endedAt": "2026-10-16T07:28:00Z",
                "playedTicks": 88_800_000_000_i64,
                "progress": 100,
                "client": "Jellyfin Web",
                "deviceName": "Firefox",
                "playMethod": "DirectPlay"
            }),
        )]],
        0,
    );

    f.sync();

    let play = &f.plays()[0];
    assert_eq!(
        play.ended_at.as_deref(),
        Some("2026-10-16T07:28:00.000000Z")
    );
    assert_eq!(play.played_seconds, Some(8_880));
    assert_eq!(play.progress, Some(100.0));
    assert_eq!(play.client.as_deref(), Some("Jellyfin Web"));
    assert_eq!(play.device_name.as_deref(), Some("Firefox"));
    assert_eq!(play.play_method.as_deref(), Some("DirectPlay"));
    // UTC user: local fields match UTC.
    assert_eq!(play.local_date, "2026-10-16");
    assert_eq!(play.local_time, "05:00");
    assert_eq!(play.local_hour, 5);
}

#[test]
fn local_time_is_the_users_clock_when_the_play_started() {
    let mut f = fixture();
    rewind::models::User::set_timezone(&f.env.conn, f.user_id, "Asia/Kolkata").unwrap();
    f.movie();
    f.env.stub_changes(
        &[vec![entry(
            1,
            &json!({"startedAt": "2026-11-09T20:00:00Z"}),
        )]],
        0,
    );

    f.sync();

    let play = &f.plays()[0];
    assert_eq!(play.local_date, "2026-11-10");
    assert_eq!(play.local_time, "01:30");
    assert_eq!(play.local_hour, 1);
    assert_eq!(play.local_weekday, 2);
    assert_eq!(play.utc_offset_minutes, 330);
    assert_eq!(play.timezone, "Asia/Kolkata");
}

#[test]
fn sends_the_stored_cursor_as_since() {
    let mut f = fixture();
    Source::save_cursor(&f.env.conn, f.source.id, Some(41)).unwrap();
    let mocks = f.env.stub_changes(&[vec![]], 41);

    f.sync();

    mocks[0].assert();
    assert_eq!(f.source().cursor.as_deref(), Some("41"));
}

#[test]
fn re_delivering_an_entry_keeps_a_single_play() {
    let mut f = fixture();
    f.movie();
    f.env
        .stub_changes(&[vec![entry(1, &json!({})), entry(2, &json!({}))]], 0);

    f.sync();

    assert_eq!(f.plays().len(), 1);
}

#[test]
fn a_play_still_under_the_scrobble_rules_is_skipped_until_it_counts() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[vec![
            entry(1, &json!({"status": "active", "scrobbled": false})),
            entry(2, &json!({"status": "active", "scrobbled": true})),
            entry(3, &json!({"status": "completed", "scrobbled": true})),
        ]],
        0,
    );

    let tally = f.sync();

    assert_eq!(f.plays().len(), 1);
    assert_eq!(tally.get(Outcome::Ignored), 1);
    assert_eq!(tally.get(Outcome::Written), 1);
}

#[test]
fn a_re_sent_play_updates_its_progress_only() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[vec![entry(
            1,
            &json!({"status": "active", "playedTicks": 600_000_000}),
        )]],
        0,
    );
    f.sync();
    let first = f.plays()[0].clone();

    f.env.stub_changes(
        &[vec![entry(
            2,
            &json!({"endedAt": "2026-10-16T07:00:00Z", "playedTicks": 72_000_000_000_i64, "genres": ["Sci-Fi"]}),
        )]],
        1,
    );
    let tally = f.sync();

    let play = &f.plays()[0];
    assert_eq!(tally.get(Outcome::Updated), 1);
    assert_eq!(play.id, first.id);
    assert_eq!(play.played_seconds, Some(7_200));
    assert_eq!(
        play.ended_at.as_deref(),
        Some("2026-10-16T07:00:00.000000Z")
    );
    assert_eq!(play.started_at, first.started_at);
    assert_eq!(play.local_time, first.local_time);
    assert_eq!(f.source().cursor.as_deref(), Some("2"));
}

#[test]
fn a_detail_change_on_a_recorded_play_is_a_no_op() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);
    f.sync();
    f.env
        .stub_changes(&[vec![entry(2, &json!({"genres": ["Sci-Fi"]}))]], 1);

    let tally = f.sync();

    assert_eq!(tally.get(Outcome::Unchanged), 1);
    assert_eq!(f.plays().len(), 1);
}

#[test]
fn a_deleted_entry_removes_only_its_own_play_and_keeps_ratings() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[vec![
            entry(1, &json!({"id": "p1"})),
            entry(2, &json!({"id": "p2"})),
        ]],
        0,
    );
    f.sync();
    let item = Item::find(&f.env.conn, f.plays()[0].item_id)
        .unwrap()
        .unwrap();
    UserItem::set_rating(&f.env.conn, f.user_id, &item.rating_key(), Some(5)).unwrap();

    f.env
        .stub_changes(&[vec![entry(3, &json!({"id": "p1", "deleted": true}))]], 2);
    f.sync();

    let events: Vec<_> = f
        .plays()
        .into_iter()
        .filter_map(|p| p.source_event_id)
        .collect();
    assert_eq!(events, ["rewind:p2"]);
    assert!(
        UserItem::find(&f.env.conn, f.user_id, &item.rating_key())
            .unwrap()
            .is_some()
    );
}

#[test]
fn an_unscrobble_removes_the_play_and_a_rescrobble_restores_it() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);
    f.sync();

    f.env
        .stub_changes(&[vec![entry(2, &json!({"scrobbled": false}))]], 1);
    f.sync();
    assert!(f.plays().is_empty());

    f.env
        .stub_changes(&[vec![entry(3, &json!({"scrobbled": true}))]], 2);
    f.sync();
    assert_eq!(f.plays()[0].source_event_id.as_deref(), Some("rewind:p1"));
}

#[test]
fn imports_plays_the_user_marked_as_played() {
    let mut f = fixture();
    f.movie();
    f.env
        .stub_changes(&[vec![entry(1, &json!({"source": "manual"}))]], 0);

    f.sync();

    assert_eq!(f.plays().len(), 1);
}

#[test]
fn pages_through_the_feed_saving_each_cursor() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[
            vec![entry(1, &json!({"id": "p1"}))],
            vec![entry(2, &json!({"id": "p2"}))],
        ],
        0,
    );

    f.sync();

    assert_eq!(f.plays().len(), 2);
    assert_eq!(f.source().cursor.as_deref(), Some("2"));
}

#[test]
fn an_item_gone_from_the_library_falls_back_to_its_stamped_item() {
    let mut f = fixture();
    let known = f.env.create_item("movie", "tmdb:1", "Known");
    rewind::models::item::Item::update(
        &f.env.conn,
        known.id,
        &rewind::models::item::Attrs::new().text("jellyfin_id", Some("m1")),
    )
    .unwrap();
    f.env.stub_item_gone("m1");
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);

    f.sync();

    assert_eq!(f.plays()[0].item_id, known.id);
}

#[test]
fn an_item_gone_from_the_library_resolves_from_the_snapshot() {
    let mut f = fixture();
    f.env.stub_tmdb_movie(27_205);
    f.env.stub_item_gone("m1");
    f.env.stub_changes(
        &[vec![entry(1, &json!({"providerIds": {"Tmdb": "27205"}}))]],
        0,
    );

    f.sync();

    let item = Item::find(&f.env.conn, f.plays()[0].item_id)
        .unwrap()
        .unwrap();
    assert_eq!(item.external_id, "tmdb:27205");
}

#[test]
fn a_gone_track_resolves_from_its_snapshotted_musicbrainz_ids() {
    let mut f = fixture();
    f.env.stub_item_gone("a1");
    f.env
        .stub_json("GET", "/Users/u-1/Items", &json!({"Items": []}));
    f.env.stub_changes(
        &[vec![entry(
            1,
            &json!({
                "itemId": "a1", "itemType": "Audio", "name": "Burnout",
                "album": "Dookie", "albumId": "alb-1", "albumArtists": ["Green Day"],
                "indexNumber": 3, "discNumber": 1,
                "providerIds": {
                    "MusicBrainzTrack": "rt-1",
                    "MusicBrainzAlbum": "rel-1",
                    "MusicBrainzAlbumArtist": "art-1"
                }
            }),
        )]],
        0,
    );

    f.sync();

    let track = Item::find(&f.env.conn, f.plays()[0].item_id)
        .unwrap()
        .unwrap();
    assert_eq!(track.external_id, "mbid:rt:rt-1");
    assert_eq!(
        track.parent_external_id.as_deref(),
        Some("mbid:release:rel-1")
    );
    assert_eq!(track.artist(), Some("Green Day"));
    assert_eq!(track.track_number(), Some(3));
}

#[test]
fn an_unmatched_scrobble_is_skipped_and_logged() {
    let mut f = fixture();
    f.env
        .stub_library_item(&json!({"Id": "a1", "Type": "Audio"}));
    f.env.stub_changes(
        &[vec![entry(
            1,
            &json!({"itemId": "a1", "itemType": "Audio", "name": null}),
        )]],
        0,
    );

    let tally = f.sync();

    assert_eq!(tally.get(Outcome::Skipped), 1);
    assert!(f.plays().is_empty());
    assert_eq!(f.source().cursor.as_deref(), Some("1"));
    let logs = ErrorLog::page(&f.env.conn, 10, 0).unwrap();
    assert!(logs[0].message.contains("Unmatched play"));
}

#[test]
fn a_failure_fetching_the_item_holds_the_cursor() {
    let mut f = fixture();
    f.env.stub_status("GET", "/Users/u-1/Items/m1", 500);
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    assert!(f.plays().is_empty());
    assert_eq!(f.source().cursor, None);
    assert!(f.source().last_error_id.is_some());
}

#[test]
fn a_server_without_the_plugin_records_a_clear_error() {
    let mut f = fixture();
    f.env.stub_status("GET", "/Rewind/History/Changes", 404);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    let error = SourceError::find(&f.env.conn, f.source().last_error_id.unwrap())
        .unwrap()
        .unwrap();
    assert!(error.message.contains("Rewind plugin not installed"));
}

#[test]
fn an_unauthorized_response_leaves_the_source_enabled() {
    let mut f = fixture();
    f.env.stub_status("GET", "/Rewind/History/Changes", 401);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    assert!(f.source().enabled);
    assert!(sync::is_auth_error(&f.try_sync().unwrap_err()));
    assert_eq!(
        f.env.count(&format!(
            "SELECT count(*) FROM source_errors WHERE source_id = {}",
            f.source.id
        )),
        2
    );
}

#[test]
fn a_successful_sync_clears_the_current_error_but_keeps_the_log() {
    let mut f = fixture();
    Source::record_error(&f.env.conn, f.source.id, "boom").unwrap();
    f.env.stub_changes(&[vec![]], 0);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    assert_eq!(f.source().last_error_id, None);
    assert_eq!(
        f.source()
            .latest_error(&f.env.conn)
            .unwrap()
            .unwrap()
            .message,
        "boom"
    );
}

#[test]
fn a_token_from_another_key_asks_to_reconnect() {
    let f = fixture();
    let mut config = f.env.config.clone();
    config.secret_key = Some(rewind::crypto::encode(&[1u8; 32]));
    sync::run_once(&config, &f.env.conn).unwrap();
    let error = SourceError::find(&f.env.conn, f.source().last_error_id.unwrap())
        .unwrap()
        .unwrap();
    assert!(
        error.message.contains("reconnect it in Settings"),
        "{}",
        error.message
    );
}

#[test]
fn the_username_is_learned_and_kept_current() {
    let mut f = fixture();
    f.env
        .stub_json("GET", "/Users/Me", &json!({"Id": "u-1", "Name": "fnando"}));
    f.env.stub_changes(&[vec![]], 0);
    f.sync();
    assert_eq!(f.source().external_user_name.as_deref(), Some("fnando"));
}

#[test]
fn a_username_that_cant_be_read_doesnt_stop_the_sync() {
    let mut f = fixture();
    Source::set_user_name(&f.env.conn, f.source.id, "fnando").unwrap();
    f.env.stub_status("GET", "/Users/Me", 500);
    f.env.stub_changes(&[vec![]], 0);

    f.sync();

    assert_eq!(f.source().external_user_name.as_deref(), Some("fnando"));
    assert_eq!(f.source().last_error_id, None);
}

#[test]
fn two_accounts_on_the_same_server_keep_their_own_plays() {
    let mut f = fixture();
    let other_user = f.env.create_user("other");
    let other = f.env.create_source(other_user.id, "u-1", "srv-1");
    f.movie();
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);

    f.sync();
    sync::sync_source(&f.env.config, &f.env.conn, &KEY, &other).unwrap();

    let mut users: Vec<i64> = f.plays().iter().map(|p| p.user_id).collect();
    users.sort_unstable();
    assert_eq!(users, [f.user_id, other_user.id]);
}

#[test]
fn a_disabled_source_is_skipped() {
    let mut f = fixture();
    Source::set_enabled(&f.env.conn, f.source.id, false).unwrap();
    let mock = f
        .env
        .stub_status("GET", "/Rewind/History/Changes", 200)
        .expect(0);

    sync::run_once(&f.env.config, &f.env.conn).unwrap();

    mock.assert();
}

#[test]
fn the_sync_command_syncs_now() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);

    let out = cli::sync(
        &f.env.config,
        &SyncArgs {
            source: None,
            reset: false,
            yes: false,
        },
    )
    .unwrap();

    assert_eq!(f.plays().len(), 1);
    assert_eq!(out, "Synced 1 source.");
}

#[test]
fn the_sync_command_needs_an_enabled_source() {
    let f = fixture();
    Source::set_enabled(&f.env.conn, f.source.id, false).unwrap();
    let error = cli::sync(
        &f.env.config,
        &SyncArgs {
            source: None,
            reset: false,
            yes: false,
        },
    )
    .unwrap_err();
    assert!(error.to_string().contains("No enabled sources"));
}

#[test]
fn reset_replaces_the_jellyfin_plays_and_keeps_everything_else() {
    let mut f = fixture();
    let old = f.env.create_item("movie", "tmdb:999", "Old");
    let play = |source: &str, source_id: Option<i64>, event: Option<&str>| {
        Play::create(
            &f.env.conn,
            &NewPlay {
                user_id: f.user_id,
                item_id: old.id,
                source: source.into(),
                source_id,
                instance_id: Some("srv-1".into()),
                source_event_id: event.map(String::from),
                ..NewPlay::default()
            },
        )
        .unwrap()
    };
    let mine = play("jellyfin", Some(f.source.id), Some("rewind:old-1"));
    let orphan = play("jellyfin", None, Some("rewind:old-2"));
    let manual = play("manual", None, None);
    UserItem::set_rating(&f.env.conn, f.user_id, &old.rating_key(), Some(5)).unwrap();
    Source::save_cursor(&f.env.conn, f.source.id, Some(99)).unwrap();
    f.movie();
    f.env.stub_changes(&[vec![entry(1, &json!({}))]], 0);

    let out = cli::sync(
        &f.env.config,
        &SyncArgs {
            source: None,
            reset: true,
            yes: true,
        },
    )
    .unwrap();

    assert!(Play::find(&f.env.conn, mine.id).unwrap().is_none());
    assert!(Play::find(&f.env.conn, orphan.id).unwrap().is_none());
    assert!(Play::find(&f.env.conn, manual.id).unwrap().is_some());
    assert_eq!(f.env.count("SELECT count(*) FROM user_items"), 1);
    assert!(
        Item::find_by_key(&f.env.conn, "movie", "tmdb:999")
            .unwrap()
            .is_some()
    );
    assert_eq!(out, "Removed 2 and imported 1 plays.");
}

#[test]
fn reset_leaves_another_accounts_plays_on_the_same_server() {
    let f = fixture();
    let other_user = f.env.create_user("other");
    let other = f.env.create_source(other_user.id, "u-2", "srv-1");
    let item = f.env.create_item("movie", "tmdb:5", "M");
    let theirs = Play::create(
        &f.env.conn,
        &NewPlay {
            user_id: other_user.id,
            item_id: item.id,
            source: "jellyfin".into(),
            source_id: Some(other.id),
            instance_id: Some("srv-1".into()),
            source_event_id: Some("rewind:theirs".into()),
            ..NewPlay::default()
        },
    )
    .unwrap();

    assert_eq!(sync::reset(&f.env.conn, &[f.source.clone()]).unwrap(), 0);
    assert!(Play::find(&f.env.conn, theirs.id).unwrap().is_some());
}

/// Another connection holds SQLite's write lock for the whole sync.
fn hold_write_lock(env: &Env) -> rusqlite::Connection {
    let blocker = rewind::db::open(&env.config.db_path(), 50).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    blocker
}

#[test]
fn a_locked_write_defers_the_entry_instead_of_failing() {
    let mut f = fixture();
    f.movie();
    let source = f.source.clone();
    let mut adapter = Adapter::new(&f.env.config, source.clone(), "tok".into());
    let _blocker = hold_write_lock(&f.env);

    let outcome =
        sync::record_entry(&f.env.conn, &source, &mut adapter, &entry(1, &json!({}))).unwrap();

    assert_eq!(outcome, Outcome::Deferred);
}

#[test]
fn a_deferred_entry_holds_the_cursor_and_still_tries_the_whole_page() {
    let mut f = fixture();
    f.movie();
    f.env.stub_changes(
        &[vec![
            entry(1, &json!({"id": "a"})),
            entry(2, &json!({"id": "b"})),
        ]],
        0,
    );
    let blocker = hold_write_lock(&f.env);

    let tally = sync::sync_source(&f.env.config, &f.env.conn, &KEY, &f.source).unwrap();
    drop(blocker);

    assert_eq!(tally.get(Outcome::Deferred), 2);
    assert_eq!(f.source().cursor, None);
    assert!(f.plays().is_empty());
}

mod common;

use common::{Env, movie_item};
use mockito::{Matcher, Mock};
use rewind::models::Source;
use rewind::models::item::{Attrs, Item};
use rewind::models::play::{NewPlay, Play};
use rewind::services::jellyfin_archive;
use rewind::services::sources::jellyfin::Adapter;
use serde_json::{Value, json};

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
    fn adapter(&self) -> Adapter {
        Adapter::new(&self.env.config, self.source.clone(), "tok".into())
    }

    fn resolve(&self, item: &Value) -> Option<Item> {
        self.adapter().resolve(&self.env.conn, item).unwrap()
    }

    fn by_key(&self, media_type: &str, external_id: &str) -> Option<Item> {
        Item::find_by_key(&self.env.conn, media_type, external_id).unwrap()
    }

    fn first(&self, tail: &str) -> Option<Item> {
        Item::first(&self.env.conn, tail, []).unwrap()
    }

    /// A feed entry for a library item, with the item stubbed as present.
    fn play_entry(&mut self, item: &Value) -> Value {
        self.env.stub_library_item(item);
        json!({
            "id": format!("p-{}", item["Id"].as_str().unwrap()),
            "itemId": item["Id"],
            "itemType": item["Type"],
            "name": item["Name"],
            "scrobbled": true,
            "startedAt": "2026-10-16T05:00:00Z"
        })
    }

    fn stub_album_tracks(&mut self, album_id: &str, items: &Value) -> Mock {
        self.env
            .server
            .mock("GET", "/Users/u-1/Items")
            .match_query(Matcher::AllOf(vec![
                Matcher::UrlEncoded("ParentId".into(), album_id.into()),
                Matcher::UrlEncoded("IncludeItemTypes".into(), "Audio".into()),
            ]))
            .with_body(json!({"Items": items}).to_string())
            .create()
    }

    fn stub_artist_albums(&mut self, artist_id: &str, items: &Value) -> Mock {
        self.env
            .server
            .mock("GET", "/Users/u-1/Items")
            .match_query(Matcher::AllOf(vec![
                Matcher::UrlEncoded("AlbumArtistIds".into(), artist_id.into()),
                Matcher::UrlEncoded("IncludeItemTypes".into(), "MusicAlbum".into()),
            ]))
            .with_body(json!({"Items": items}).to_string())
            .create()
    }

    fn stub_item(&mut self, id: &str, attrs: &Value) -> Mock {
        let mut body = attrs.clone();
        body["Id"] = json!(id);
        self.env
            .stub_json("GET", &format!("/Users/u-1/Items/{id}"), &body)
    }
}

fn audio_item(id: &str, name: &str, index: i64) -> Value {
    json!({
        "Id": id, "Type": "Audio", "Name": name, "Album": "Dookie",
        "AlbumArtist": "Green Day", "ParentId": "alb-1", "IndexNumber": index
    })
}

fn album_item(id: &str, name: &str, mbid: &str) -> Value {
    json!({
        "Id": id, "Type": "MusicAlbum", "Name": name, "AlbumArtist": "Green Day",
        "ProviderIds": {"MusicBrainzAlbum": mbid, "MusicBrainzAlbumArtist": "art-1"}
    })
}

/// A played track carrying its MusicBrainz ids and the artist's Jellyfin id.
fn tagged_track(id: &str, name: &str) -> Value {
    let mut track = audio_item(id, name, 1);
    track["ProviderIds"] = json!({
        "MusicBrainzTrack": format!("rt-{id}"),
        "MusicBrainzAlbum": "rg-1",
        "MusicBrainzAlbumArtist": "art-1"
    });
    track["AlbumArtists"] = json!([{"Name": "Green Day", "Id": "jf-artist-1"}]);
    track
}

fn merge(base: &Value, extra: &Value) -> Value {
    let mut out = base.clone();
    for (k, v) in extra.as_object().unwrap() {
        out[k] = v.clone();
    }
    out
}

#[test]
fn resolves_a_movie() {
    let mut f = fixture();
    f.env.stub_tmdb_movie(27_205);
    let item = f.resolve(&movie_item("m1")).unwrap();
    assert_eq!(item.media_type, "movie");
    assert_eq!(item.external_id, "tmdb:27205");
    assert_eq!(item.title, "Inception");
}

#[test]
fn resolves_a_movie_by_its_imdb_id() {
    let mut f = fixture();
    f.env.stub_tmdb_movie(27_205);
    f.env
        .stub_tmdb_find_imdb("tt1375666", &json!({"movie_results": [{"id": 27_205}]}));
    let item = f
        .resolve(&json!({"Id": "m1", "Type": "Movie", "Name": "Inception", "ProviderIds": {"Imdb": "tt1375666"}}))
        .unwrap();
    assert_eq!(item.external_id, "tmdb:27205");
}

#[test]
fn keeps_an_unmatched_episode_as_a_generic_series_and_episode() {
    let f = fixture();
    let item = f
        .resolve(&json!({
            "Id": "ep-jf-1", "Type": "Episode", "Name": "ESCRITÓRIO CHATGPT",
            "RunTimeTicks": 1_800_243_080_i64, "PremiereDate": "2026-07-01T00:00:00Z",
            "ProductionYear": 2026, "IndexNumber": 70_198, "ParentIndexNumber": 2026,
            "ProviderIds": {"youtube": "9n6sxWtYz6I"},
            "SeriesName": "Porta dos Fundos", "SeriesId": "series-jf-1",
            "SeriesPrimaryImageTag": "stag", "ImageTags": {"Primary": "etag"}
        }))
        .unwrap();
    assert_eq!(item.media_type, "episode");
    assert_eq!(item.external_id, "youtube:9n6sxWtYz6I");
    assert_eq!(
        item.parent_external_id.as_deref(),
        Some("jellyfin:series-jf-1")
    );
    assert_eq!(item.title, "ESCRITÓRIO CHATGPT");
    assert_eq!(item.release_date.as_deref(), Some("2026-07-01"));
    assert_eq!(item.runtime, Some(3));
    assert_eq!(item.meta_str("source"), Some("jellyfin"));
    assert_eq!(
        item.poster_path.as_deref(),
        Some("/Items/ep-jf-1/Images/Primary?tag=etag")
    );
    let series = f.by_key("series", "jellyfin:series-jf-1").unwrap();
    assert_eq!(series.title, "Porta dos Fundos");
    assert_eq!(
        series.poster_path.as_deref(),
        Some("/Items/series-jf-1/Images/Primary?tag=stag")
    );
}

#[test]
fn keeps_a_standalone_video_as_a_generic_movie() {
    let f = fixture();
    let item = f
        .resolve(&json!({
            "Id": "vid-1", "Type": "Video", "Name": "Photography Course",
            "ImageTags": {"Primary": "ptag"}, "ProviderIds": {"youtube": "abc123"}
        }))
        .unwrap();
    assert_eq!(item.media_type, "movie");
    assert_eq!(item.external_id, "youtube:abc123");
    assert_eq!(item.meta_str("source"), Some("jellyfin"));
}

fn music_video() -> Value {
    json!({
        "Id": "mv-1", "Type": "MusicVideo", "Name": "Basket Case",
        "Artists": ["Green Day"], "RunTimeTicks": 1_800_000_000_i64,
        "PremiereDate": "1994-02-01T00:00:00Z",
        "ImageTags": {"Primary": "mvtag"}, "ProviderIds": {"youtube": "mv-yt"}
    })
}

#[test]
fn resolves_a_music_video_linked_to_its_artist() {
    let f = fixture();
    let artist = f.env.create_item("artist", "mbid:artist:a1", "Green Day");
    let item = f.resolve(&music_video()).unwrap();
    assert_eq!(item.media_type, "music_video");
    assert_eq!(item.external_id, "youtube:mv-yt");
    assert_eq!(item.artist(), Some("Green Day"));
    assert_eq!(
        item.parent_external_id.as_deref(),
        Some(artist.external_id.as_str())
    );
    assert_eq!(item.runtime, Some(3));
    assert_eq!(item.release_date.as_deref(), Some("1994-02-01"));
}

#[test]
fn keeps_a_music_video_without_a_matching_artist_as_text() {
    let f = fixture();
    let item = f.resolve(&music_video()).unwrap();
    assert_eq!(item.parent_external_id, None);
    assert_eq!(item.meta_str("artist_external_id"), None);
    assert_eq!(item.artist(), Some("Green Day"));
}

#[test]
fn reads_a_music_videos_artist_from_its_path() {
    let f = fixture();
    f.env.create_item("artist", "mbid:artist:a1", "Green Day");
    let item = f
        .resolve(&merge(
            &music_video(),
            &json!({"Artists": [], "Path": "/music/Green Day/Basket Case.mp4"}),
        ))
        .unwrap();
    assert_eq!(item.artist(), Some("Green Day"));
    assert_eq!(item.meta_str("artist_external_id"), Some("mbid:artist:a1"));
}

#[test]
fn stamps_the_jellyfin_id_on_a_played_music_video_and_movie() {
    let mut f = fixture();
    f.env.stub_tmdb_movie(27_205);
    let video = f.play_entry(&music_video());
    let movie = f.play_entry(&movie_item("m1"));
    let mut adapter = f.adapter();
    adapter.resolve_entry(&f.env.conn, &video).unwrap();
    adapter.resolve_entry(&f.env.conn, &movie).unwrap();
    assert_eq!(
        f.first("WHERE media_type = 'music_video'")
            .unwrap()
            .jellyfin_id
            .as_deref(),
        Some("mv-1")
    );
    assert_eq!(
        f.by_key("movie", "tmdb:27205")
            .unwrap()
            .jellyfin_id
            .as_deref(),
        Some("m1")
    );
}

#[test]
fn groups_a_video_in_a_nested_folder_under_a_folder_series() {
    let mut f = fixture();
    f.stub_item(
        "f-sub",
        &json!({"Type": "Folder", "ParentId": "f-root", "Name": "35mm Film Photography", "ImageTags": {"Primary": "ft"}}),
    );
    f.stub_item(
        "f-root",
        &json!({"Type": "Folder", "Name": "other", "ParentId": "coll"}),
    );
    let item = f
        .resolve(&json!({"Id": "v9", "Type": "Video", "Name": "001 - Intro", "ParentId": "f-sub"}))
        .unwrap();
    assert_eq!(item.media_type, "episode");
    assert_eq!(item.parent_external_id.as_deref(), Some("jellyfin:f-sub"));
    assert_eq!(
        f.by_key("series", "jellyfin:f-sub").unwrap().title,
        "35mm Film Photography"
    );
}

#[test]
fn keeps_a_loose_video_in_the_library_root_as_a_movie() {
    let mut f = fixture();
    f.stub_item(
        "f-root",
        &json!({"Type": "Folder", "Name": "other", "ParentId": "coll"}),
    );
    f.stub_item(
        "coll",
        &json!({"Type": "CollectionFolder", "Name": "other"}),
    );
    let item = f
        .resolve(
            &json!({"Id": "v10", "Type": "Video", "Name": "A Fat Wreck", "ParentId": "f-root"}),
        )
        .unwrap();
    assert_eq!(item.media_type, "movie");
    assert_eq!(item.external_id, "jellyfin:v10");
}

#[test]
fn an_audio_item_without_a_name_isnt_kept() {
    let mut f = fixture();
    let entry = f.play_entry(&json!({"Id": "a1", "Type": "Audio"}));
    assert!(
        f.adapter()
            .resolve_entry(&f.env.conn, &entry)
            .unwrap()
            .is_none()
    );
}

#[test]
fn resolves_an_episode_via_the_series_tmdb_id() {
    let mut f = fixture();
    f.stub_item("series-1", &json!({"ProviderIds": {"Tmdb": "1399"}}));
    f.env.stub_tmdb_tv(1399, "Game of Thrones");
    f.env.stub_tmdb_episode(1399, 1, 2, "The Kingsroad");
    let item = f
        .resolve(&json!({
            "Id": "e1", "Type": "Episode", "SeriesId": "series-1",
            "ParentIndexNumber": 1, "IndexNumber": 2
        }))
        .unwrap();
    assert_eq!(item.media_type, "episode");
    assert_eq!(item.episode_number, Some(2));
    assert_eq!(item.title, "The Kingsroad");
    assert_eq!(item.meta_str("series_name"), Some("Game of Thrones"));
    assert!(f.by_key("series", "tmdb:1399").is_some());
}

#[test]
fn resolves_audio_from_its_musicbrainz_ids() {
    let f = fixture();
    let item = f
        .resolve(&json!({
            "Id": "a1", "Type": "Audio", "Name": "Burnout", "Album": "Dookie",
            "AlbumArtist": "Green Day", "RunTimeTicks": 1_280_000_000_i64,
            "ProviderIds": {
                "MusicBrainzTrack": "rt-1", "MusicBrainzAlbum": "rel-1",
                "MusicBrainzAlbumArtist": "art-1"
            }
        }))
        .unwrap();
    assert_eq!(item.media_type, "track");
    assert_eq!(item.external_id, "mbid:rt:rt-1");
    assert_eq!(
        item.parent_external_id.as_deref(),
        Some("mbid:release:rel-1")
    );
    assert_eq!(item.artist(), Some("Green Day"));
}

fn retagged_track() -> Value {
    json!({
        "Id": "jf-new", "Type": "Audio", "Name": "The Thief", "Album": "Mmhmm",
        "AlbumArtist": "Relient K", "ServerId": "srv-1", "ParentId": "alb-1",
        "RunTimeTicks": 1_280_000_000_i64,
        "ProviderIds": {
            "MusicBrainzTrack": "rt-new", "MusicBrainzAlbum": "rel-1",
            "MusicBrainzAlbumArtist": "art-1", "MusicBrainzRecording": "rec-1"
        }
    })
}

fn stranded_old_play(f: &Fixture) -> Item {
    let old = Item::upsert(
        &f.env.conn,
        "track",
        "mbid:rt:rt-old",
        &Attrs::new()
            .text("title", Some("The Thief"))
            .text("parent_external_id", Some("mbid:release:rel-old"))
            .text("jellyfin_id", Some("jf-old")),
    )
    .unwrap();
    Play::create(
        &f.env.conn,
        &NewPlay {
            user_id: f.user_id,
            item_id: old.id,
            source: "jellyfin".into(),
            instance_id: Some("srv-1".into()),
            source_event_id: Some("e-old".into()),
            started_at: Some("2026-10-10T12:00:00Z".parse().unwrap()),
            ..NewPlay::default()
        },
    )
    .unwrap();
    jellyfin_archive::remember(
        &f.env.conn,
        &old,
        Some("jf-old"),
        "track",
        "srv-1",
        Some("rec-1"),
    )
    .unwrap();
    old
}

#[test]
fn a_retagged_tracks_new_id_reclaims_the_stranded_play() {
    let mut f = fixture();
    let old = stranded_old_play(&f);
    f.stub_album_tracks("alb-1", &json!([retagged_track()]));
    let gone = f.env.stub_status("GET", "/Users/u-1/Items/jf-old", 404);

    let adapter = &mut f.adapter();
    let item = adapter
        .resolve(&f.env.conn, &retagged_track())
        .unwrap()
        .unwrap();
    // A second sighting doesn't run the healer again.
    adapter.resolve(&f.env.conn, &retagged_track()).unwrap();

    assert_eq!(item.external_id, "mbid:rt:rt-new");
    assert!(Item::find(&f.env.conn, old.id).unwrap().is_none());
    assert_eq!(
        f.env.count(&format!(
            "SELECT count(*) FROM plays WHERE item_id = {}",
            item.id
        )),
        1
    );
    gone.expect(1).assert();
}

#[test]
fn a_split_release_is_credited_to_its_first_artist() {
    let f = fixture();
    let item = f
        .resolve(&json!({
            "Id": "split-t1", "Type": "Audio", "Name": "Swiss Army Bro-Mance",
            "Album": "Swiss Army Bro-Mance", "ServerId": "srv-1",
            "AlbumArtist": "New Found Glory / Dashboard Confessional",
            "AlbumArtists": [{"Name": "New Found Glory"}, {"Name": "Dashboard Confessional"}],
            "RunTimeTicks": 1_280_000_000_i64,
            "ProviderIds": {
                "MusicBrainzTrack": "rt-split", "MusicBrainzAlbum": "rel-split",
                "MusicBrainzAlbumArtist": "nfg-id", "MusicBrainzRecording": "rec-split"
            }
        }))
        .unwrap();
    assert_eq!(item.artist(), Some("New Found Glory"));
    assert_eq!(
        item.meta_str("artist_external_id"),
        Some("mbid:artist:nfg-id")
    );
    assert_eq!(
        f.by_key("artist", "mbid:artist:nfg-id").unwrap().title,
        "New Found Glory"
    );
}

#[test]
fn a_splits_combined_id_and_name_from_the_plugin_collapse_to_the_lead() {
    let mut f = fixture();
    f.env.stub_json(
        "GET",
        "/AudioMetadata/Album/split-alb",
        &json!({"Tracks": [{
            "ItemId": "split-t1",
            "RawTags": {
                "MUSICBRAINZ_ALBUMID": "rel-split",
                "MUSICBRAINZ_ALBUMARTISTID": "nfg-id; dc-id",
                "ALBUMARTISTS": "New Found Glory; Dashboard",
                "MUSICBRAINZ_RELEASETRACKID": "rt-split"
            }
        }]}),
    );
    let split = json!({
        "Id": "split-t1", "Type": "Audio", "ParentId": "split-alb",
        "Name": "The Swiss Army Romance", "Album": "Swiss Army Bro-Mance",
        "ServerId": "srv-1", "AlbumArtists": [],
        "AlbumArtist": "New Found Glory / Dashboard Confessional",
        "RunTimeTicks": 1_280_000_000_i64,
        "ProviderIds": {
            "MusicBrainzTrack": "rt-split", "MusicBrainzAlbum": "rel-split",
            "MusicBrainzAlbumArtist": "nfg-id; dc-id"
        }
    });
    f.stub_album_tracks("split-alb", &json!([split]));

    let item = f.resolve(&split).unwrap();

    assert_eq!(item.artist(), Some("New Found Glory"));
    assert_eq!(
        item.meta_str("artist_external_id"),
        Some("mbid:artist:nfg-id")
    );
    assert!(f.first("WHERE external_id LIKE '%;%'").is_none());
}

#[test]
fn a_single_artist_with_a_slash_in_the_name_stays_whole() {
    let f = fixture();
    let item = f
        .resolve(&json!({
            "Id": "bc-t1", "Type": "Audio", "Name": "Warriors", "Album": "Warriors",
            "AlbumArtist": "Bad Cop/Bad Cop", "AlbumArtists": [{"Name": "Bad Cop/Bad Cop"}],
            "ProviderIds": {"MusicBrainzTrack": "rt-bc", "MusicBrainzAlbum": "rel-bc", "MusicBrainzAlbumArtist": "bc-id"}
        }))
        .unwrap();
    assert_eq!(item.artist(), Some("Bad Cop/Bad Cop"));
}

#[test]
fn backfills_an_albums_unplayed_tracks() {
    let mut f = fixture();
    f.stub_album_tracks(
        "alb-1",
        &json!([
            audio_item("a1", "Burnout", 1),
            audio_item("a2", "Having a Blast", 2),
            audio_item("a3", "Chump", 3)
        ]),
    );
    f.resolve(&audio_item("a1", "Burnout", 1));
    let tracks = Item::list(&f.env.conn, "WHERE media_type = 'track' ORDER BY title", []).unwrap();
    let titles: Vec<&str> = tracks.iter().map(|t| t.title.as_str()).collect();
    assert_eq!(titles, ["Burnout", "Chump", "Having a Blast"]);
    let numbers: Vec<Option<i64>> = tracks.iter().map(Item::track_number).collect();
    assert_eq!(numbers, [Some(1), Some(3), Some(2)]);
    assert_eq!(f.env.count("SELECT count(*) FROM plays"), 0);
}

#[test]
fn fetches_an_albums_tracklist_once_per_run() {
    let mut f = fixture();
    let mock = f.stub_album_tracks("alb-1", &json!([])).expect(1);
    let mut adapter = f.adapter();
    adapter
        .resolve(&f.env.conn, &audio_item("a1", "Burnout", 1))
        .unwrap();
    adapter
        .resolve(&f.env.conn, &audio_item("a2", "Having a Blast", 2))
        .unwrap();
    mock.assert();
}

#[test]
fn refetches_the_tracklist_on_a_later_run() {
    let mut f = fixture();
    let mock = f.stub_album_tracks("alb-1", &json!([])).expect(2);
    f.resolve(&audio_item("a1", "Burnout", 1));
    f.resolve(&audio_item("a1", "Burnout", 1));
    mock.assert();
}

#[test]
fn stores_the_albums_release_date_and_genres() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    f.resolve(&merge(
        &audio_item("a1", "Burnout", 1),
        &json!({"PremiereDate": "1994-02-01T00:00:00Z", "Genres": ["Punk Rock", "Alternative Rock"]}),
    ));
    let album = f.first("WHERE media_type = 'album'").unwrap();
    assert_eq!(album.release_date.as_deref(), Some("1994-02-01"));
    assert_eq!(album.genres(), ["Punk Rock", "Alternative Rock"]);
}

#[test]
fn an_unchanged_etag_skips_the_re_resolve() {
    let mut f = fixture();
    let mock = f.stub_album_tracks("alb-1", &json!([])).expect(1);
    let tagged = merge(&audio_item("a1", "Burnout", 1), &json!({"Etag": "v1"}));
    let first = f.resolve(&tagged).unwrap();
    let second = f.resolve(&tagged).unwrap();
    assert_eq!(first.id, second.id);
    assert_eq!(
        Item::find(&f.env.conn, first.id)
            .unwrap()
            .unwrap()
            .source_etag
            .as_deref(),
        Some("v1")
    );
    mock.assert();
}

#[test]
fn a_changed_etag_re_resolves() {
    let mut f = fixture();
    let mock = f.stub_album_tracks("alb-1", &json!([])).expect(2);
    f.resolve(&merge(
        &audio_item("a1", "Burnout", 1),
        &json!({"Etag": "v1"}),
    ));
    f.resolve(&merge(
        &audio_item("a1", "Burnout", 1),
        &json!({"Etag": "v2"}),
    ));
    mock.assert();
}

#[test]
fn backfills_an_artists_unplayed_albums() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    f.stub_artist_albums(
        "jf-artist-1",
        &json!([
            album_item("alb-1", "Dookie", "rg-1"),
            album_item("alb-2", "Insomniac", "rg-2"),
            album_item("alb-3", "Nimrod", "rg-3")
        ]),
    );
    f.resolve(&tagged_track("a1", "Burnout"));
    let artist = f.first("WHERE media_type = 'artist'").unwrap();
    let albums = Item::list(&f.env.conn, "WHERE media_type = 'album' ORDER BY title", []).unwrap();
    let titles: Vec<&str> = albums.iter().map(|a| a.title.as_str()).collect();
    assert_eq!(titles, ["Dookie", "Insomniac", "Nimrod"]);
    assert!(
        albums
            .iter()
            .all(|a| a.parent_external_id.as_deref() == Some(artist.external_id.as_str()))
    );
}

#[test]
fn fetches_an_artists_albums_once_per_run() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    let mock = f
        .stub_artist_albums(
            "jf-artist-1",
            &json!([album_item("alb-1", "Dookie", "rg-1")]),
        )
        .expect(1);
    let mut adapter = f.adapter();
    adapter
        .resolve(&f.env.conn, &tagged_track("a1", "Burnout"))
        .unwrap();
    adapter
        .resolve(&f.env.conn, &tagged_track("a2", "Chump"))
        .unwrap();
    mock.assert();
}

#[test]
fn caches_an_albums_release_type() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    f.stub_artist_albums(
        "jf-artist-1",
        &json!([
            album_item("alb-1", "Dookie", "rg-1"),
            album_item("alb-2", "Insomniac", "rg-2")
        ]),
    );
    f.env.stub_json(
        "GET",
        "/AudioMetadata/Album/alb-2",
        &json!({"Tracks": [{"ReleaseType": "EP"}]}),
    );
    f.resolve(&tagged_track("a1", "Burnout"));
    let insomniac = f.first("WHERE title = 'Insomniac'").unwrap();
    let dookie = f.first("WHERE title = 'Dookie'").unwrap();
    assert_eq!(insomniac.meta_str("release_type"), Some("ep"));
    assert_eq!(dookie.meta_str("release_type"), None);

    // A later resolve of the album keeps the cached type.
    f.resolve(&tagged_track("a1", "Burnout"));
    let insomniac = f.first("WHERE title = 'Insomniac'").unwrap();
    assert_eq!(insomniac.meta_str("release_type"), Some("ep"));
}

#[test]
fn resolves_an_album_to_its_release_via_the_plugin() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    f.stub_artist_albums(
        "jf-artist-1",
        &json!([{
            "Id": "alb-9", "Type": "MusicAlbum", "Name": "Kerplunk", "AlbumArtist": "Green Day",
            "ProviderIds": {"MusicBrainzAlbumArtist": "art-1"}
        }]),
    );
    f.env.stub_json(
        "GET",
        "/AudioMetadata/Album/alb-9",
        &json!({"Tracks": [{"ItemId": "jf-k1", "MusicBrainzAlbumId": "rel-9", "RawTags": {"MUSICBRAINZ_ALBUMARTISTID": "art-1"}}]}),
    );
    f.resolve(&tagged_track("a1", "Burnout"));
    let kerplunk = f.first("WHERE title = 'Kerplunk'").unwrap();
    assert_eq!(kerplunk.external_id, "mbid:release:rel-9");
    assert_eq!(
        kerplunk.parent_external_id.as_deref(),
        Some("mbid:artist:art-1")
    );
}

#[test]
fn an_album_with_a_release_id_is_keyed_by_the_release_not_the_group() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    f.stub_artist_albums(
        "jf-artist-1",
        &json!([{
            "Id": "alb-7", "Type": "MusicAlbum", "Name": "Kerplunk", "AlbumArtist": "Green Day",
            "ProviderIds": {"MusicBrainzAlbum": "rel-7", "MusicBrainzReleaseGroup": "rg-7", "MusicBrainzAlbumArtist": "art-1"}
        }]),
    );
    f.resolve(&tagged_track("a1", "Burnout"));
    assert_eq!(
        f.first("WHERE title = 'Kerplunk'").unwrap().external_id,
        "mbid:release:rel-7"
    );
}

#[test]
fn stamps_jellyfin_ids_on_a_played_track_and_its_album() {
    let mut f = fixture();
    f.stub_album_tracks("alb-1", &json!([]));
    let entry = f.play_entry(&audio_item("a1", "Burnout", 1));
    f.adapter().resolve_entry(&f.env.conn, &entry).unwrap();
    assert_eq!(
        f.first("WHERE media_type = 'track'")
            .unwrap()
            .jellyfin_id
            .as_deref(),
        Some("a1")
    );
    assert_eq!(
        f.first("WHERE media_type = 'album'")
            .unwrap()
            .jellyfin_id
            .as_deref(),
        Some("alb-1")
    );
}

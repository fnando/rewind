use mockito::{Matcher, Server};
use rewind::services::jellyfin::{AlbumTrack, Client, Error, PLUGIN_ID};
use serde_json::json;

fn client(server: &Server) -> Client {
    Client::new(&server.url(), Some("t".into()))
}

#[test]
fn public_users_lists_id_and_name() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/Public")
        .with_body(
            json!([{"Id": "abc", "Name": "fnando"}, {"Id": "def", "Name": "guga"}]).to_string(),
        )
        .create();
    let users = Client::new(&format!("{}/", server.url()), None).public_users();
    assert_eq!(
        users,
        vec![
            ("abc".into(), "fnando".into()),
            ("def".into(), "guga".into())
        ]
    );
}

#[test]
fn public_users_is_empty_on_failure() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/Public")
        .with_status(404)
        .create();
    assert!(Client::new(&server.url(), None).public_users().is_empty());
    assert!(
        Client::new("http://127.0.0.1:1", None)
            .public_users()
            .is_empty()
    );
}

#[test]
fn authenticate_returns_the_token_and_user() {
    let mut server = Server::new();
    server
        .mock("POST", "/Users/AuthenticateByName")
        .match_body(Matcher::Json(json!({"Username": "fnando", "Pw": "secret"})))
        .match_header("authorization", Matcher::Regex("DeviceId=\"[0-9a-f]{32}\"".into()))
        .with_body(
            json!({"AccessToken": "tok-123", "User": {"Id": "u-1", "Name": "fnando"}, "ServerId": "srv-9"})
                .to_string(),
        )
        .create();
    let auth = Client::new(&server.url(), None)
        .authenticate("fnando", "secret")
        .unwrap();
    assert_eq!(auth.access_token, "tok-123");
    assert_eq!(auth.user_id, "u-1");
    assert_eq!(auth.user_name.as_deref(), Some("fnando"));
    assert_eq!(auth.server_id.as_deref(), Some("srv-9"));
}

#[test]
fn authenticate_rejects_bad_credentials() {
    let mut server = Server::new();
    server
        .mock("POST", "/Users/AuthenticateByName")
        .with_status(401)
        .create();
    let error = Client::new(&server.url(), None)
        .authenticate("x", "y")
        .unwrap_err();
    assert!(matches!(error, Error::Auth(_)));
}

#[test]
fn album_tracks_lists_the_audio_children() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/u-1/Items")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("ParentId".into(), "alb-1".into()),
            Matcher::UrlEncoded("IncludeItemTypes".into(), "Audio".into()),
            Matcher::Regex("Fields=[^&]*AlbumArtists".into()),
        ]))
        .with_body(json!({"Items": [{"Id": "t1"}, {"Id": "t2"}]}).to_string())
        .create();
    let tracks = client(&server).album_tracks("u-1", "alb-1");
    let ids: Vec<&str> = tracks.iter().map(|t| t["Id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["t1", "t2"]);
}

#[test]
fn album_tracks_is_empty_on_failure() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/u-1/Items")
        .match_query(Matcher::Any)
        .with_status(500)
        .create();
    assert!(client(&server).album_tracks("u-1", "alb-x").is_empty());
}

#[test]
fn artist_albums_asks_for_album_artists() {
    let mut server = Server::new();
    let mock = server
        .mock("GET", "/Users/u/Items")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("AlbumArtistIds".into(), "art".into()),
            Matcher::Regex("Fields=[^&]*AlbumArtists".into()),
        ]))
        .with_body(json!({"Items": []}).to_string())
        .create();
    client(&server).artist_albums("u", "art");
    mock.assert();
}

#[test]
fn album_metadata_reads_release_artist_and_tracks() {
    let mut server = Server::new();
    server
        .mock("GET", "/AudioMetadata/Album/alb-1")
        .with_body(
            json!({"Tracks": [{
                "ItemId": "jf-t1",
                "ReleaseType": "Album",
                "MusicBrainzAlbumId": "rel-1",
                "MusicBrainzTrackId": "rec-1",
                "RawTags": {
                    "MUSICBRAINZ_RELEASETRACKID": "rt-1",
                    "MUSICBRAINZ_ALBUMARTISTID": "art-1; art-2",
                    "ALBUMARTISTS": "Artist One; Artist Two"
                }
            }]})
            .to_string(),
        )
        .create();
    let meta = client(&server).album_metadata("alb-1");
    assert_eq!(meta.release_type.as_deref(), Some("album"));
    assert_eq!(meta.release.as_deref(), Some("rel-1"));
    assert_eq!(meta.artist.as_deref(), Some("art-1"));
    assert_eq!(meta.artist_name.as_deref(), Some("Artist One"));
    assert_eq!(
        meta.tracks,
        vec![AlbumTrack {
            item_id: "jf-t1".into(),
            release_track: "rt-1".into(),
            recording: Some("rec-1".into())
        }]
    );
}

#[test]
fn album_metadata_is_empty_without_the_plugin() {
    let mut server = Server::new();
    server
        .mock("GET", "/AudioMetadata/Album/x")
        .with_status(404)
        .create();
    assert_eq!(client(&server).album_metadata("x"), Default::default());
}

#[test]
fn item_present_is_a_tri_state() {
    let mut server = Server::new();
    for (path, status) in [
        ("/Users/u/Items/a", 200),
        ("/Users/u/Items/b", 404),
        ("/Users/u/Items/c", 500),
        ("/Users/u/Items/d", 401),
    ] {
        server.mock("GET", path).with_status(status).create();
    }
    let c = client(&server);
    assert_eq!(
        ["a", "b", "c", "d"].map(|id| c.item_present("u", id)),
        [Some(true), Some(false), None, None]
    );
}

#[test]
fn rewind_changes_reads_a_page() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/History/Changes")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("since".into(), "12".into()),
            Matcher::UrlEncoded("limit".into(), "1000".into()),
        ]))
        .match_header("authorization", "MediaBrowser Token=\"t\"")
        .with_body(json!({"items": [{"id": "p1"}], "nextSince": 13, "hasMore": false}).to_string())
        .create();
    let page = client(&server).rewind_changes(12, 1000).unwrap();
    assert_eq!(page["nextSince"], 13);
    assert_eq!(page["items"][0]["id"], "p1");
}

#[test]
fn rewind_changes_reports_a_missing_plugin() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/History/Changes")
        .match_query(Matcher::Any)
        .with_status(404)
        .create();
    assert!(matches!(
        client(&server).rewind_changes(0, 1000),
        Err(Error::PluginMissing(_))
    ));
}

#[test]
fn rewind_changes_rejects_a_response_that_isnt_the_feed() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/History/Changes")
        .match_query(Matcher::Any)
        .with_body(json!({"Items": [], "NextSince": 0}).to_string())
        .create();
    let error = client(&server).rewind_changes(0, 1000).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("Unexpected Rewind changes response")
    );
}

#[test]
fn rewind_changes_reports_unauthorized() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/History/Changes")
        .match_query(Matcher::Any)
        .with_status(401)
        .create();
    assert!(matches!(
        client(&server).rewind_changes(0, 1000),
        Err(Error::Auth(_))
    ));
}

#[test]
fn library_item_asks_for_the_resolver_fields() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/u-1/Items/m1")
        .match_query(Matcher::Regex("Fields=[^&]*Etag".into()))
        .with_body(json!({"Id": "m1", "Etag": "e"}).to_string())
        .create();
    let item = client(&server).library_item("u-1", "m1").unwrap().unwrap();
    assert_eq!(item["Etag"], "e");
}

#[test]
fn library_item_is_none_when_deleted_and_errors_on_failures() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/u-1/Items/gone")
        .match_query(Matcher::Any)
        .with_status(404)
        .create();
    server
        .mock("GET", "/Users/u-1/Items/down")
        .match_query(Matcher::Any)
        .with_status(503)
        .create();
    let c = client(&server);
    assert!(c.library_item("u-1", "gone").unwrap().is_none());
    assert!(c.library_item("u-1", "down").is_err());
}

#[test]
fn server_id_reads_the_public_info() {
    let mut server = Server::new();
    server
        .mock("GET", "/System/Info/Public")
        .with_body(r#"{"Id":"srv-1"}"#)
        .create();
    assert_eq!(client(&server).server_id().as_deref(), Some("srv-1"));
}

#[test]
fn current_user_name_reads_users_me() {
    let mut server = Server::new();
    server
        .mock("GET", "/Users/Me")
        .with_body(r#"{"Name":"fnando"}"#)
        .create();
    assert_eq!(
        client(&server).current_user_name().as_deref(),
        Some("fnando")
    );
}

#[test]
fn rewind_info_confirms_the_plugin_without_signing_in() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/Info")
        .match_header("authorization", Matcher::Missing)
        .with_body(json!({"id": PLUGIN_ID, "version": "1.0.0"}).to_string())
        .create();
    let info = Client::new(&server.url(), None).rewind_info().unwrap();
    assert_eq!(info["version"], "1.0.0");
}

#[test]
fn rewind_info_accepts_the_id_without_dashes() {
    let mut server = Server::new();
    server
        .mock("GET", "/Rewind/Info")
        .with_body(json!({"id": "6bcfddb4c3fb48f6996f5b02d07e3e62", "name": "Rewind"}).to_string())
        .create();
    let info = Client::new(&server.url(), None).rewind_info().unwrap();
    assert_eq!(info["name"], "Rewind");
}

#[test]
fn rewind_info_reports_a_server_without_the_plugin() {
    let mut bare = Server::new();
    bare.mock("GET", "/Rewind/Info").with_status(404).create();
    let mut other = Server::new();
    other
        .mock("GET", "/Rewind/Info")
        .with_body("<html></html>")
        .create();
    for server in [&bare, &other] {
        assert!(matches!(
            Client::new(&server.url(), None).rewind_info(),
            Err(Error::PluginMissing(_))
        ));
    }
}

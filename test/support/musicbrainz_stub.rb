# frozen_string_literal: true

module MusicBrainzStub
  def stub_mb_recording(mbid, title: "Paranoid", length: 240_000,
                        artist_name: "Black Sabbath", artist_mbid: "artist-1",
                        album_title: "Paranoid", rg_mbid: "rg-1",
                        genres: [{"name" => "metal"}])
    body = {
      "id" => mbid,
      "title" => title,
      "length" => length,
      "artist-credit" => [
        {
          "name" => artist_name,
          "artist" => {"id" => artist_mbid, "name" => artist_name}
        }
      ],
      "releases" => [
        {
          "id" => "release-1", "title" => album_title,
          "release-group" => {"id" => rg_mbid, "title" => album_title}
        }
      ],
      "genres" => genres
    }
    WebMock.stub_request(:get, %r{musicbrainz\.org/ws/2/recording/#{mbid}})
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  def stub_mb_search(mbid, title: "Found")
    body = {"recordings" => [{"id" => mbid, "title" => title}]}
    WebMock.stub_request(:get, %r{musicbrainz\.org/ws/2/recording\?})
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  def stub_mb_search_empty
    WebMock.stub_request(:get, %r{musicbrainz\.org/ws/2/recording\?})
           .to_return(status: 200, body: {"recordings" => []}.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  def stub_fanart_artist(mbid, url: "https://fanart.example/artist.jpg")
    body = {"artistthumb" => [{"url" => url}]}
    WebMock.stub_request(:get, %r{webservice\.fanart\.tv/v3\.2/music/#{mbid}})
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end
end

Minitest::Test.include(MusicBrainzStub)

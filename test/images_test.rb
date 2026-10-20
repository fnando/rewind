# frozen_string_literal: true

require "test_helper"

class ImagesProxyTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
    @image_dir = Dir.mktmpdir("rewind-img-")
    Rewind.config.image_storage_dir = @image_dir
    @helper = Object.new.extend(Rewind::Helpers::ViewHelper)

    @item = create_item(media_type: "movie", title: "Heat",
                        external_id: "tmdb:949", poster_path: "/heat.jpg")
    @remote = "https://image.tmdb.org/t/p/w500/heat.jpg"
    @url = @helper.poster_url(@item)
  end

  def teardown
    Rewind.config.image_storage_dir = nil
    FileUtils.remove_entry(@image_dir) if @image_dir && File.exist?(@image_dir)
  end

  test "poster_url routes items through the local image proxy" do
    Rewind::Play.create(user_id: @user.id, item_id: @item.id,
                        played_at: Time.now, source: "manual")

    get "/history"

    assert_includes last_response.body, @helper.poster_url(@item)
  end

  test "a cache miss resolves the upstream, caches it, and serves bytes" do
    WebMock.stub_request(:get, @remote)
           .to_return(status: 200, body: "JPEGBYTES",
                      headers: {"Content-Type" => "image/jpeg"})

    get @url

    assert_equal 200, last_response.status
    assert_equal "image/jpeg", last_response.headers["content-type"]
    assert_equal "JPEGBYTES", last_response.body
    cached = File.join(@image_dir, File.basename(@url))

    assert File.file?(cached)
    assert_equal "JPEGBYTES", File.binread(cached)
  end

  test "a cached file is served by the middleware without refetching" do
    File.binwrite(File.join(@image_dir, File.basename(@url)), "CACHED")

    get @url

    assert_equal 200, last_response.status
    assert_equal "CACHED", last_response.body
    assert_includes last_response.headers["cache-control"], "immutable"
  end

  test "a thumbnail on a configured source host is proxied" do
    create_source(user_id: @user.id, url: "https://jf.test")
    remote = "https://jf.test/Items/x/Images/Primary?tag=t"
    artist = create_item(media_type: "artist", external_id: "mbid:artist:jf",
                         title: "Chan", poster_path: remote)
    WebMock.stub_request(:get, remote)
           .to_return(status: 200, body: "THUMB",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(artist)

    assert_equal 200, last_response.status
    assert_equal "THUMB", last_response.body
  end

  test "an upstream from a disallowed host falls back to the placeholder" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:x",
                         title: "X", poster_path: "https://evil.example/p.jpg")

    get @helper.poster_url(artist)

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/poster-placeholder.svg"
  end

  test "a relative jellyfin image resolves its host from the source" do
    create_source(user_id: @user.id, url: "http://jellyfin:8096")
    ep = create_item(media_type: "episode", external_id: "jellyfin:ep1",
                     title: "Ep",
                     poster_path: "/Items/ep1/Images/Primary?tag=t")
    remote = "http://jellyfin:8096/Items/ep1/Images/Primary?tag=t"
    WebMock.stub_request(:get, remote)
           .to_return(status: 200, body: "EPIMG",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(ep)

    assert_equal 200, last_response.status
    assert_equal "EPIMG", last_response.body
  end

  test "a jellyfin image with a stale host is re-hosted to the source" do
    # A poster_path pinned to another environment's host (e.g. restored across
    # installs) must still serve — the host is re-resolved, not trusted.
    create_source(user_id: @user.id, url: "http://jellyfin:8096")
    ep = create_item(
      media_type: "episode", external_id: "jellyfin:ep2", title: "Ep2",
      poster_path: "https://old.example/Items/ep2/Images/Primary?tag=t"
    )
    remote = "http://jellyfin:8096/Items/ep2/Images/Primary?tag=t"
    WebMock.stub_request(:get, remote)
           .to_return(status: 200, body: "IMG2",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(ep)

    assert_equal 200, last_response.status
    assert_equal "IMG2", last_response.body
  end

  test "remote_poster_url re-hosts jellyfin images, leaving tmdb alone" do
    create_source(user_id: @user.id, url: "http://jellyfin:8096/")
    rel = create_item(media_type: "episode", external_id: "jellyfin:e1",
                      title: "E1",
                      poster_path: "/Items/e1/Images/Primary?tag=t")
    abs = create_item(
      media_type: "episode", external_id: "jellyfin:e2", title: "E2",
      poster_path: "https://stale.example/Items/e2/Images/Primary?tag=t"
    )
    tmdb = create_item(media_type: "movie", external_id: "tmdb:1", title: "M",
                       poster_path: "/p.jpg")

    assert_equal "http://jellyfin:8096/Items/e1/Images/Primary?tag=t",
                 @helper.remote_poster_url(rel)
    assert_equal "http://jellyfin:8096/Items/e2/Images/Primary?tag=t",
                 @helper.remote_poster_url(abs)
    assert_equal "https://image.tmdb.org/t/p/w185/p.jpg",
                 @helper.remote_poster_url(tmdb)
  end

  test "tracks that share an album cover resolve to one proxied URL" do
    two = (1..2).map do |n|
      create_item(media_type: "track", external_id: "mbid:t#{n}",
                  title: "Track #{n}",
                  metadata_json: {"album_external_id" => "mbid:rg:1"}.to_json)
    end

    urls = two.map {|track| @helper.poster_url(track) }

    assert_equal 1, urls.uniq.size
  end

  test "an artist with no stored art is re-fetched via fanart and backfilled" do
    original_key = Rewind.config.fanart_api_key
    Rewind.config.fanart_api_key = "fanart-key"
    artist = create_item(media_type: "artist", external_id: "mbid:artist:abc",
                         title: "Radiohead", poster_path: nil)
    thumb = "https://assets.fanart.tv/music/abc/artistthumb/a.jpg"
    WebMock.stub_request(:get, %r{webservice\.fanart\.tv/.+/music/abc})
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"artistthumb" => [{"url" => thumb}]}.to_json)
    WebMock.stub_request(:get, thumb)
           .to_return(status: 200, body: "ARTBYTES",
                      headers: {"Content-Type" => "image/jpeg"})

    begin
      get @helper.poster_url(artist)
    ensure
      Rewind.config.fanart_api_key = original_key
    end

    assert_equal 200, last_response.status
    assert_equal "ARTBYTES", last_response.body
    assert_equal thumb, artist.refresh.poster_path # backfilled, self-heals
  end

  test "logs the resolve/download on a miss and the hit on a cached serve" do
    WebMock.stub_request(:get, @remote)
           .to_return(status: 200, body: "JPEGBYTES",
                      headers: {"Content-Type" => "image/jpeg"})

    io = StringIO.new
    original_level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::INFO

    begin
      get @url # miss -> resolve + download + store
      get @url # hit  -> served from disk
    ensure
      Rewind.logger.level = original_level
      Rewind.logger.reopen($stdout)
    end

    assert_includes io.string, "[images] miss movie:tmdb:949, downloading"
    assert_includes io.string, "[images] stored movie:tmdb:949"
    assert_includes io.string, "[images] hit #{File.basename(@url)}"
  end

  test "a season cover resolves its poster from the series metadata" do
    create_item(
      media_type: "series", external_id: "tmdb:1399", title: "GoT",
      metadata_json: {
        "seasons" => [
          {"season_number" => 1, "poster_path" => "/s1.jpg"},
          {"season_number" => 2, "poster_path" => "/s2.jpg"}
        ]
      }.to_json
    )
    cover = Rewind::Presenters::PlayCard::SeasonCover.new("season",
                                                          "tmdb:1399:2")
    remote = "https://image.tmdb.org/t/p/w500/s2.jpg"
    WebMock.stub_request(:get, remote)
           .to_return(status: 200, body: "S2IMG",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(cover)

    assert_equal 200, last_response.status
    assert_equal "S2IMG", last_response.body
  end

  test "a season with no stored poster falls back to the placeholder" do
    create_item(
      media_type: "series", external_id: "tmdb:1399", title: "GoT",
      metadata_json: {"seasons" => [{"season_number" => 1}]}.to_json
    )
    cover = Rewind::Presenters::PlayCard::SeasonCover.new("season",
                                                          "tmdb:1399:1")

    get @helper.poster_url(cover)

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/poster-placeholder.svg"
  end

  test "a synthetic music item falls back to its Jellyfin artwork" do
    # No MusicBrainz match (synthetic id) means no Cover Art Archive entry and
    # no poster_path; the item's own Jellyfin image is the only source.
    create_source(user_id: @user.id, url: "http://jellyfin:8096")
    album = create_item(media_type: "album", title: "B-Sides",
                        external_id: "mbid:synthetic:album:abc",
                        jellyfin_id: "jf-album-1")
    remote = "http://jellyfin:8096/Items/jf-album-1/Images/Primary"
    WebMock.stub_request(:get, remote)
           .to_return(status: 200, body: "ALBUMART",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(album)

    assert_equal 200, last_response.status
    assert_equal "ALBUMART", last_response.body
    assert_equal remote, album.refresh.poster_path # backfilled, self-heals
  end

  test "a dead Cover Art Archive cover heals to the Jellyfin artwork" do
    # A real release-group id whose Cover Art Archive entry 404s: the stored
    # URL fails, so we fall through to the album's own Jellyfin image and heal
    # poster_path to it.
    create_source(user_id: @user.id, url: "http://jellyfin:8096")
    dead = "https://coverartarchive.org/release-group/rg-1/front-250"
    album = create_item(media_type: "album", title: "B-Sides",
                        external_id: "mbid:rg:rg-1", poster_path: dead,
                        jellyfin_id: "jf-dead-1")
    jelly = "http://jellyfin:8096/Items/jf-dead-1/Images/Primary"
    WebMock.stub_request(:get, dead).to_return(status: 404)
    WebMock.stub_request(:get, jelly)
           .to_return(status: 200, body: "JELLYART",
                      headers: {"Content-Type" => "image/jpeg"})

    get @helper.poster_url(album)

    assert_equal 200, last_response.status
    assert_equal "JELLYART", last_response.body
    assert_equal jelly, album.refresh.poster_path # healed off the dead URL
  end

  test "image requests do not require authentication" do
    File.binwrite(File.join(@image_dir, File.basename(@url)), "CACHED")
    clear_cookies

    get @url

    assert_equal 200, last_response.status
    assert_equal "CACHED", last_response.body
  end
end

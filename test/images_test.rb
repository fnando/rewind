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
    @remote = "https://image.tmdb.org/t/p/w185/heat.jpg"
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

    assert_includes last_response.body, @url
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

  test "image requests do not require authentication" do
    File.binwrite(File.join(@image_dir, File.basename(@url)), "CACHED")
    clear_cookies

    get @url

    assert_equal 200, last_response.status
    assert_equal "CACHED", last_response.body
  end
end

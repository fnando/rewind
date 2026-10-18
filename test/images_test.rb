# frozen_string_literal: true

require "test_helper"

class ImagesProxyTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
    @image_dir = Dir.mktmpdir("rewind-img-")
    Rewind.config.image_storage_dir = @image_dir

    @item = create_item(media_type: "movie", title: "Heat",
                        poster_path: "/heat.jpg")
    @remote = "https://image.tmdb.org/t/p/w185/heat.jpg"
    @url = proxied_url(@remote)
  end

  def teardown
    Rewind.config.image_storage_dir = nil
    FileUtils.remove_entry(@image_dir) if @image_dir && File.exist?(@image_dir)
  end

  # The proxy keys on the upstream URL, so this mirrors poster_url's scheme.
  def proxied_url(remote)
    "/images/#{Base64.urlsafe_encode64(remote, padding: false)}.jpg"
  end

  test "poster_url routes items through the local image proxy" do
    Rewind::Play.create(user_id: @user.id, item_id: @item.id,
                        played_at: Time.now, source: "manual")

    get "/history"

    assert_includes last_response.body, @url
  end

  test "a cache miss fetches the upstream image, caches it, and serves bytes" do
    stub = WebMock.stub_request(:get, @remote)
                  .to_return(status: 200, body: "JPEGBYTES",
                             headers: {"Content-Type" => "image/jpeg"})

    get @url

    assert_equal 200, last_response.status
    assert_equal "image/jpeg", last_response.headers["content-type"]
    assert_equal "JPEGBYTES", last_response.body
    assert_requested(stub, at_least_times: 1)
    # The bytes are written to the storage dir for next time.
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

  test "an upstream from a disallowed host falls back to the placeholder" do
    get proxied_url("https://evil.example/pic.jpg")

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/poster-placeholder.svg"
  end

  test "tracks that share an album cover resolve to one proxied URL" do
    cover = "https://coverartarchive.org/release-group/rg-1/front-250"
    two = (1..2).map do |n|
      create_item(media_type: "track", external_id: "mbid:t#{n}",
                  title: "Track #{n}", poster_path: cover,
                  metadata_json: {"album_external_id" => "mbid:rg:1"}.to_json)
    end

    helper = Object.new.extend(Rewind::Helpers::ViewHelper)
    urls = two.map {|track| helper.poster_url(track) }

    assert_equal 1, urls.uniq.size
    assert_equal proxied_url(cover), urls.first
  end

  test "logs the download on a miss and the hit on a cached serve" do
    WebMock.stub_request(:get, @remote)
           .to_return(status: 200, body: "JPEGBYTES",
                      headers: {"Content-Type" => "image/jpeg"})

    io = StringIO.new
    original_level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::INFO

    begin
      get @url # miss -> download + store
      get @url # hit  -> served from disk
    ensure
      Rewind.logger.level = original_level
      Rewind.logger.reopen($stdout)
    end

    assert_includes io.string, "[images] miss #{File.basename(@url)}"
    assert_includes io.string, "[images] stored #{File.basename(@url)}"
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

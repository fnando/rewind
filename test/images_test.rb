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
    @url = proxied_url(@item, @remote, "w185")
  end

  def teardown
    Rewind.config.image_storage_dir = nil
    FileUtils.remove_entry(@image_dir) if @image_dir && File.exist?(@image_dir)
  end

  def proxied_url(item, remote, size)
    digest = Digest::MD5.hexdigest(remote)[0, 8]
    "/images/#{item.id}-#{size}-#{digest}.jpg"
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
    item = create_item(media_type: "artist", title: "X",
                       poster_path: "https://evil.example/pic.jpg")
    url = proxied_url(item, "https://evil.example/pic.jpg", "w185")

    get url

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/poster-placeholder.svg"
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

# frozen_string_literal: true

require "test_helper"
require "stringio"
require "zip"
require "rewind/services/importers/trakt"

class ImportTraktTest < Minitest::Test
  MOVIE_TMDB = 27_205
  SHOW_TMDB = 1399

  def setup
    @user = create_user(username: "trakt-user")
  end

  def capture
    out = $stdout
    err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = out
    $stderr = err
  end

  # Build a throwaway archive from a hash of {filename => ruby_data}.
  def build_archive(entries)
    path = File.join(TEST_DATA_DIR, "trakt-#{SecureRandom.hex(4)}.zip")
    Zip::File.open(path, create: true) do |zip|
      entries.each do |name, data|
        zip.get_output_stream(name) {|f| f.write(JSON.generate(data)) }
      end
    end
    path
  end

  def history_movie(id: 111, tmdb: MOVIE_TMDB,
                    watched_at: "2026-10-14T05:49:00.000Z")
    {
      "id" => id, "watched_at" => watched_at, "type" => "movie",
      "movie" => {
        "ids" => {"tmdb" => tmdb}, "title" => "Inception",
        "year" => 2010
      }
    }
  end

  def history_episode(id: 222, show_tmdb: SHOW_TMDB, season: 1, number: 2,
                      watched_at: "2026-10-15T07:46:00.000Z")
    {
      "id" => id, "watched_at" => watched_at, "type" => "episode",
      "episode" => {
        "ids" => {"tmdb" => 888}, "season" => season,
        "number" => number, "title" => "Episode"
      },
      "show" => {
        "ids" => {"tmdb" => show_tmdb}, "title" => "Game of Thrones",
        "year" => 2011
      }
    }
  end

  def import(archive)
    Rewind::Services::Importers::Trakt.new(
      user: @user, archive:, out: StringIO.new
    ).call
  end

  test "imports a movie watching as a trakt play" do
    stub_tmdb_movie(MOVIE_TMDB)
    archive = build_archive("watched-history.json" => [history_movie])

    stats = import(archive)

    play = Rewind::Play.where(user_id: @user.id).first

    assert_equal 1, stats[:plays_created]
    assert_equal "trakt", play.source
    assert_nil play.integration_id
    assert_equal "Inception", play.item.title
    assert_equal Time.parse("2026-10-14T05:49:00.000Z").to_i,
                 play.played_at.to_i
  end

  test "imports an episode watching" do
    stub_tmdb_tv(SHOW_TMDB)
    stub_tmdb_episode(SHOW_TMDB, 1, 2)
    archive = build_archive("watched-history.json" => [history_episode])

    import(archive)

    play = Rewind::Play.where(user_id: @user.id).first

    assert_equal "episode", play.item.media_type
    assert_equal 1, play.item.season_number
    assert_equal 2, play.item.episode_number
  end

  test "is idempotent across repeated runs" do
    stub_tmdb_movie(MOVIE_TMDB)
    archive = build_archive("watched-history.json" => [history_movie])

    import(archive)
    stats = import(archive)

    assert_equal 0, stats[:plays_created]
    assert_equal 1, stats[:plays_skipped]
    assert_equal 1, Rewind::Play.where(user_id: @user.id).count
  end

  test "imports a movie rating mapped from 1-10 to 1-5" do
    stub_tmdb_movie(MOVIE_TMDB)
    archive = build_archive(
      "ratings-movies.json" => [
        {
          "rating" => 8, "type" => "movie",
          "movie" => {"ids" => {"tmdb" => MOVIE_TMDB}, "title" => "Inception"}
        }
      ]
    )

    import(archive)

    item = Rewind::Item.where(external_id: "tmdb:#{MOVIE_TMDB}",
                              media_type: "movie").first
    ui = Rewind::UserItem.where(user_id: @user.id, item_id: item.id).first

    assert_equal 4, ui.rating
  end

  test "imports a show review into the user item" do
    stub_tmdb_tv(SHOW_TMDB)
    archive = build_archive(
      "comments-shows.json" => [
        {
          "type" => "show",
          "show" => {"ids" => {"tmdb" => SHOW_TMDB}, "title" => "GoT"},
          "comment" => {
            "comment" => "So much fun!",
            "created_at" => "2026-10-16T00:19:50.000Z",
            "updated_at" => "2026-10-16T00:19:50.000Z"
          }
        }
      ]
    )

    import(archive)

    item = Rewind::Item.where(external_id: "tmdb:#{SHOW_TMDB}",
                              media_type: "tv").first
    ui = Rewind::UserItem.where(user_id: @user.id, item_id: item.id).first

    assert_equal "So much fun!", ui.review
    assert_equal Time.parse("2026-10-16T00:19:50.000Z").to_i,
                 ui.review_created_at.to_i
  end

  test "a rating and a review on the same item share one user item" do
    stub_tmdb_tv(SHOW_TMDB)
    archive = build_archive(
      "ratings-shows.json" => [
        {
          "rating" => 10, "type" => "show",
          "show" => {"ids" => {"tmdb" => SHOW_TMDB}, "title" => "GoT"}
        }
      ],
      "comments-shows.json" => [
        {
          "type" => "show",
          "show" => {"ids" => {"tmdb" => SHOW_TMDB}, "title" => "GoT"},
          "comment" => {
            "comment" => "Loved it.",
            "created_at" => "2026-10-16T00:19:50.000Z",
            "updated_at" => "2026-10-16T00:19:50.000Z"
          }
        }
      ]
    )

    import(archive)

    item = Rewind::Item.where(external_id: "tmdb:#{SHOW_TMDB}",
                              media_type: "tv").first
    rows = Rewind::UserItem.where(user_id: @user.id, item_id: item.id).all

    assert_equal 1, rows.length
    assert_equal 5, rows.first.rating
    assert_equal "Loved it.", rows.first.review
  end

  test "tolerates missing and empty entries" do
    stub_tmdb_movie(MOVIE_TMDB)
    archive = build_archive(
      "watched-history.json" => [history_movie],
      "ratings-movies.json" => [],
      "ratings-seasons.json" => [{"rating" => 7, "type" => "season"}]
    )

    stats = import(archive)

    assert_equal 1, stats[:plays_created]
  end

  test "import:trakt CLI command imports from an archive" do
    stub_tmdb_movie(MOVIE_TMDB)
    archive = build_archive("watched-history.json" => [history_movie])

    out, = capture do
      Rewind::CLI.start(
        ["import:trakt", "--archive", archive, "--username", @user.username]
      )
    end

    assert_includes out, "Import complete"
    assert_equal 1, Rewind::Play.where(user_id: @user.id).count
  end

  test "import:trakt aborts when the user does not exist" do
    archive = build_archive("watched-history.json" => [])

    assert_raises(SystemExit) do
      capture do
        Rewind::CLI.start(
          ["import:trakt", "--archive", archive, "--username", "ghost"]
        )
      end
    end
  end

  test "import:trakt aborts when the archive is missing" do
    assert_raises(SystemExit) do
      capture do
        Rewind::CLI.start(
          [
            "import:trakt", "--archive", "/nope/none.zip",
            "--username", @user.username
          ]
        )
      end
    end
  end
end

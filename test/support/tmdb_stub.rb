# frozen_string_literal: true

module TMDBStub
  def stub_tmdb_movie(id, title: "Inception", runtime: 148, genres: [{"id" => 18, "name" => "Drama"}])
    body = {
      "id" => id,
      "title" => title,
      "overview" => "A heist inside dreams.",
      "release_date" => "2010-07-16",
      "poster_path" => "/poster.jpg",
      "runtime" => runtime,
      "genres" => genres,
      "credits" => {
        "crew" => [{"job" => "Director", "name" => "Christopher Nolan"}],
        "cast" => [{"name" => "Leonardo DiCaprio"}]
      }
    }
    WebMock.stub_request(:get, %r{api\.themoviedb\.org/3/movie/#{id}})
      .to_return(status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_tmdb_tv(id, name: "Game of Thrones", genres: [{"name" => "Fantasy"}], run_time: [60])
    body = {
      "id" => id,
      "name" => name,
      "genres" => genres,
      "episode_run_time" => run_time,
      "credits" => {"crew" => [{"job" => "Creator", "name" => "David Benioff"}], "cast" => []}
    }
    WebMock.stub_request(:get, %r{api\.themoviedb\.org/3/tv/#{id}(?!/)})
      .to_return(status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_tmdb_find_imdb(imdb_id, movie_results: [], tv_results: [])
    body = {"movie_results" => movie_results, "tv_results" => tv_results}
    WebMock.stub_request(:get, %r{api\.themoviedb\.org/3/find/#{imdb_id}})
      .to_return(status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_tmdb_episode(show_id, season, episode, title: "The Kingsroad")
    body = {
      "id" => (show_id * 1000) + (season * 100) + episode,
      "name" => title,
      "overview" => "On the Kingsroad.",
      "air_date" => "2011-04-24",
      "still_path" => "/still.jpg",
      "runtime" => 56,
      "credits" => {}
    }
    WebMock.stub_request(:get, %r{api\.themoviedb\.org/3/tv/#{show_id}/season/#{season}/episode/#{episode}})
      .to_return(status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"})
  end
end

Minitest::Test.include(TMDBStub)

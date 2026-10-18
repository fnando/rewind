# frozen_string_literal: true

require "httpx"

module Rewind
  module Services
    class TMDB
      Error = Class.new(Rewind::Error)
      BASE_URL = "https://api.themoviedb.org/3"
      CACHE_TTL_DAYS = 7

      def initialize(api_key: Rewind.config.tmdb_api_key)
        @api_key = api_key
      end

      def search_multi(query)
        return [] if query.to_s.strip.empty?

        results = get("/search/multi", query: query)["results"] || []
        results.filter_map {|r| normalize_search_result(r) }
      end

      def movie(tmdb_id)
        cache_item("movie", tmdb_id) do
          data = get("/movie/#{tmdb_id}", append_to_response: "credits")
          build_movie_attrs(data)
        end
      end

      def tv(tmdb_id)
        get("/tv/#{tmdb_id}", append_to_response: "credits")
      end

      def tv_item(tmdb_id)
        cache_item("series", tmdb_id) do
          data = tv(tmdb_id)

          {
            media_type: "series",
            external_id: "tmdb:#{data['id']}",
            title: data["name"] || data["original_name"],
            overview: data["overview"],
            release_date: data["first_air_date"],
            poster_path: data["poster_path"],
            runtime: data["episode_run_time"]&.first,
            metadata: {
              "series_name" => data["name"],
              "genres" => data["genres"],
              "credits" => data["credits"],
              "number_of_seasons" => data["number_of_seasons"],
              "seasons" => Array(data["seasons"]).map do |s|
                s.slice("season_number", "name", "episode_count")
              end
            }
          }
        end
      end

      def season(show_id, season_number)
        get("/tv/#{show_id}/season/#{season_number}")
      end

      def find_by_imdb(imdb_id)
        get("/find/#{imdb_id}", external_source: "imdb_id")
      end

      def episode(show_id, season, ep)
        cache_item("episode", "#{show_id}:#{season}:#{ep}",
                   tmdb_lookup: {show_id: show_id, season: season, ep: ep}) do
          data = get("/tv/#{show_id}/season/#{season}/episode/#{ep}",
                     append_to_response: "credits")
          tv_item(show_id)
          show = tv(show_id)
          build_episode_attrs(data, show, show_id, season, ep)
        end
      end

      private def normalize_search_result(result)
        case result["media_type"]
        when "movie"
          {
            media_type: "movie",
            tmdb_id: result["id"],
            title: result["title"] || result["original_title"],
            overview: result["overview"],
            release_date: result["release_date"],
            poster_path: result["poster_path"]
          }
        when "tv"
          {
            media_type: "series",
            tmdb_id: result["id"],
            title: result["name"] || result["original_name"],
            overview: result["overview"],
            release_date: result["first_air_date"],
            poster_path: result["poster_path"]
          }
        end
      end

      private def cache_item(media_type, cache_key, tmdb_lookup: nil)
        existing =
          if media_type == "episode"
            Rewind::Item.where(
              media_type: "episode",
              parent_external_id: "tmdb:#{tmdb_lookup[:show_id]}",
              season_number: tmdb_lookup[:season],
              episode_number: tmdb_lookup[:ep]
            ).first
          else
            Rewind::Item.where(media_type: media_type,
                               external_id: "tmdb:#{cache_key}").first
          end

        cache_cutoff = Time.now - (CACHE_TTL_DAYS * 86_400)

        if existing&.fetched_at && existing.fetched_at > cache_cutoff
          return existing
        end

        attrs = yield

        if existing
          existing.update(attrs.merge(fetched_at: Time.now))
          existing
        else
          Rewind::Item.create(attrs.merge(fetched_at: Time.now))
        end
      end

      private def build_movie_attrs(data)
        {
          media_type: "movie",
          external_id: "tmdb:#{data['id']}",
          title: data["title"] || data["original_title"],
          overview: data["overview"],
          release_date: data["release_date"],
          poster_path: data["poster_path"],
          runtime: data["runtime"],
          metadata: {
            "genres" => data["genres"],
            "credits" => data["credits"]
          }
        }
      end

      private def build_episode_attrs(data, show, show_id, season, ep)
        {
          media_type: "episode",
          external_id: "tmdb:#{data['id']}",
          parent_external_id: "tmdb:#{show_id}",
          season_number: season,
          episode_number: ep,
          title: data["name"],
          overview: data["overview"],
          release_date: data["air_date"],
          poster_path: data["still_path"],
          runtime: data["runtime"] || show["episode_run_time"]&.first,
          metadata: {
            "series_name" => show["name"],
            "genres" => show["genres"],
            "credits" => data["credits"] || show["credits"]
          }
        }
      end

      private def get(path, params = {})
        raise Error, "TMDB_API_KEY not configured" if @api_key.to_s.empty?

        response = HTTPX
                   .with(headers: {
                           "Authorization" => "Bearer #{@api_key}",
                           "Accept" => "application/json"
                         })
                   .get("#{BASE_URL}#{path}", params: params)

        if response.is_a?(HTTPX::ErrorResponse)
          raise Error, "TMDB request failed: #{response.error.message}"
        end
        unless response.status.between?(200, 299)
          raise Error, "TMDB request failed: #{response.status}"
        end

        JSON.parse(response.body.to_s)
      end
    end
  end
end

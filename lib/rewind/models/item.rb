# frozen_string_literal: true

module Rewind
  class Item < Sequel::Model
    one_to_many :plays

    MEDIA_TYPES = %w[movie episode series track album artist music_video].freeze

    def metadata
      return {} if metadata_json.nil? || metadata_json.empty?

      @metadata ||= JSON.parse(metadata_json)
    end

    def metadata=(hash)
      @metadata = nil
      self.metadata_json = hash.nil? ? nil : JSON.generate(hash)
    end

    # The numeric TMDB id lives inside external_id ("tmdb:603"); expose it for
    # the TMDB API call sites that still pass a bare id.
    def tmdb_id
      id_from(external_id)
    end

    def parent_tmdb_id
      id_from(parent_external_id)
    end

    def mbid
      external_id.to_s.start_with?("mbid:") ? external_id.sub("mbid:", "") : nil
    end

    def genres
      Array(metadata["genres"]).filter_map {|g| g.is_a?(Hash) ? g["name"] : g }
    end

    def credits
      metadata["credits"] || {}
    end

    def artist
      metadata["artist"]
    end

    def album
      metadata["album"]
    end

    # A stable key for ratings/reviews that survives rebuilding `items`. The
    # Jellyfin id (stable across re-tagging) when present, else the
    # deterministic (media_type, external_id) — which a rebuild reproduces.
    def rating_key
      jellyfin_id ? "jellyfin:#{jellyfin_id}" : "#{media_type}:#{external_id}"
    end

    def track_number
      metadata["track_number"]
    end

    def disc_number
      metadata["disc_number"]
    end

    def display_title
      case media_type
      when "episode"
        parent = metadata["series_name"]
        season = season_number.to_s.rjust(2, "0")
        episode = episode_number.to_s.rjust(2, "0")
        "#{parent} S#{season}E#{episode} · #{title}"
      when "track", "music_video"
        artist ? "#{artist} — #{title}" : title
      else
        title
      end
    end

    private def id_from(value)
      value.to_s.start_with?("tmdb:") ? value.sub("tmdb:", "").to_i : nil
    end
  end
end

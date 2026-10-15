# frozen_string_literal: true

module Rewind
  class Item < Sequel::Model
    one_to_many :plays

    MEDIA_TYPES = %w[movie episode tv].freeze

    def metadata
      return {} if metadata_json.nil? || metadata_json.empty?

      @metadata ||= JSON.parse(metadata_json)
    end

    def metadata=(hash)
      @metadata = nil
      self.metadata_json = hash.nil? ? nil : JSON.generate(hash)
    end

    def genres
      Array(metadata["genres"]).filter_map {|g| g.is_a?(Hash) ? g["name"] : g }
    end

    def credits
      metadata["credits"] || {}
    end

    def display_title
      if media_type == "episode"
        parent = metadata["series_name"]
        season = season_number.to_s.rjust(2, "0")
        episode = episode_number.to_s.rjust(2, "0")
        "#{parent} S#{season}E#{episode} · #{title}"
      else
        title
      end
    end
  end
end

# frozen_string_literal: true

module Rewind
  module Presenters
    # Wraps a Play with its preloaded relations and derives everything a
    # History cover card needs, keeping the per-kind branching out of the ERB.
    class PlayCard
      # A season's cover art, which has no Item of its own: it stands in for
      # the series on an episode card when that season carries its own poster.
      # Quacks like an item for poster_owner (media_type + external_id only).
      SeasonCover = Data.define(:media_type, :external_id)

      attr_reader :play, :item

      def initialize(play, shows: {}, music_parents: {}, user_items: {})
        @play = play
        @item = play.item
        @shows = shows || {}
        @music_parents = music_parents || {}
        @user_items = user_items || {}
      end

      def id
        play.id
      end

      def played_at
        play.played_at
      end

      def user_item
        @user_items[@item.id]
      end

      # movie / episode / track / music_video — drives the aspect ratio and
      # badge.
      def kind
        @item.media_type
      end

      def kind_label
        {
          "movie" => "Movie", "episode" => "Episode",
          "track" => "Track", "music_video" => "Music Video"
        }.fetch(kind, kind.to_s.capitalize)
      end

      # The series item behind an episode play, when it's loaded.
      def show
        return unless kind == "episode"

        @shows[@item.parent_external_id]
      end

      # The item the title links to — always the play's own item (the episode
      # itself for episode plays; the series moves into the detail line).
      def link_item
        @item
      end

      # The item whose cover art the card shows. Episodes prefer their season's
      # poster, falling back to the series (then the episode itself); the album
      # resolves underneath poster_url for tracks.
      def cover_item
        return @item unless kind == "episode"

        season_cover || show || @item
      end

      # A SeasonCover when the series carries a poster for this episode's
      # season, else nil so cover_item falls back to the show's own art.
      private def season_cover
        return unless (series = show)

        season = Array(series.metadata["seasons"]).find do |s|
          s["season_number"].to_i == @item.season_number.to_i
        end
        return if season.nil? || season["poster_path"].to_s.empty?

        id = "#{series.external_id}:#{@item.season_number}"
        SeasonCover.new("season", id)
      end

      # The card's main title: the episode title for episodes, else the item's
      # own title.
      def title
        @item.title
      end

      # The show name behind an episode play, for its detail line.
      def series_name
        @item.metadata["series_name"] || show&.title || @item.title
      end

      def source_label
        play.source.to_s.capitalize
      end

      # The release year for a movie's detail line, or "".
      def movie_year
        @item.release_date.to_s[0, 4]
      end

      # The "S1 · E2" (or Jellyfin air date) prefix before an episode title,
      # or nil when neither is known.
      def episode_prefix
        if @item.metadata["source"] == "jellyfin"
          @item.release_date ? air_date : nil
        else
          "S#{@item.season_number} · E#{@item.episode_number}"
        end
      end

      # The artist/album items behind a track play, for linking its detail.
      def artist_item
        @music_parents[@item.metadata["artist_external_id"]]
      end

      def album_item
        @music_parents[@item.metadata["album_external_id"]]
      end

      private def air_date
        Date.parse(@item.release_date.to_s).strftime("%b %-d, %Y")
      rescue ArgumentError
        @item.release_date.to_s
      end
    end
  end
end

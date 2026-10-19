# frozen_string_literal: true

module Rewind
  module Presenters
    # Wraps a Play with its preloaded relations and derives everything a
    # History cover card needs, keeping the per-kind branching out of the ERB.
    class PlayCard
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

      # movie / episode / track — drives the aspect ratio and badge.
      def kind
        @item.media_type
      end

      def kind_label
        {
          "movie" => "Movie", "episode" => "Episode",
          "track" => "Track"
        }.fetch(kind, kind.to_s.capitalize)
      end

      # The series item behind an episode play, when it's loaded.
      def show
        return unless kind == "episode"

        @shows[@item.parent_external_id]
      end

      # The item the title links to: the series for episodes, else the play's
      # own item.
      def link_item
        kind == "episode" ? (show || @item) : @item
      end

      # The item whose cover art the card shows: the series for episodes; the
      # album resolves underneath poster_url for tracks.
      def cover_item
        kind == "episode" ? (show || @item) : @item
      end

      def title
        return @item.metadata["series_name"] || show&.title || @item.title if
          kind == "episode"

        @item.title
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

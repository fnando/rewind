# frozen_string_literal: true

module Rewind
  module Services
    # Builds a music_video Item from already-extracted fields.
    #
    # There's no external metadata provider for the video itself (TMDB is for
    # movies/TV, MusicBrainz for audio), so a music video is Jellyfin-native —
    # we keep its own title/runtime/art and link it to its artist by name. The
    # artist is matched against an existing `artist` Item (created by the audio
    # path) by a normalized title match; when none matches we still keep the
    # video, showing the artist name as plain text.
    module MusicVideo
      # The artist Item whose title matches +name+ (case-insensitive, trimmed),
      # or nil. Name matching can miss when the folder/tag name differs from the
      # MusicBrainz artist title, or match the wrong same-named artist — both
      # are accepted; the caller falls back to plain text.
      def self.artist_item_for(name)
        normalized = name.to_s.strip.downcase
        return if normalized.empty?

        Rewind::Item
          .where(media_type: "artist")
          .where(Sequel.function(:lower, :title) => normalized)
          .first
      end

      # Upsert a music_video Item (keyed, like the other Jellyfin-native items,
      # on (media_type, external_id)). When the artist resolves, the video is
      # parented under it (so it shows on the artist page) and carries the same
      # `artist_external_id` metadata key tracks use, so the history card/detail
      # linking lights up for free.
      def self.build(external_id:, title:, artist_name:, runtime: nil,
                     release_date: nil, poster_path: nil, jellyfin_id: nil)
        artist = artist_item_for(artist_name)
        artist_external_id = artist&.external_id
        attrs = {
          title: title,
          parent_external_id: artist_external_id,
          release_date: release_date,
          runtime: runtime,
          poster_path: poster_path,
          fetched_at: Time.now,
          metadata: {
            "artist" => artist_name,
            "artist_external_id" => artist_external_id,
            "source" => "jellyfin"
          }
        }
        # Only set the stable id when we have one, so a later build can fill it
        # without an earlier nil clearing it back out.
        attrs[:jellyfin_id] = jellyfin_id if jellyfin_id

        existing = Rewind::Item.where(media_type: "music_video",
                                      external_id: external_id).first
        if existing
          existing.update(attrs)
          existing
        else
          Rewind::Item.create(
            attrs.merge(media_type: "music_video", external_id: external_id)
          )
        end
      end
    end
  end
end

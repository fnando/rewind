# frozen_string_literal: true

require "base64"

module Rewind
  module Helpers
    module ViewHelper
      def h(value)
        Rack::Utils.escape_html(value.to_s)
      end

      # The version of the time zone database currently loaded — the synced copy
      # when present, otherwise the bundled gem. See Services::TimezoneData.
      def tzdata_version
        require "tzinfo/data"
        TZInfo::Data::VERSION
      rescue StandardError, LoadError
        nil
      end

      def current_user
        @current_user
      end

      # Whether the signed-in user has any source with an unresolved sync error.
      # Drives the topbar avatar alert dot. One small, user-scoped query.
      def sync_errors?
        return false unless current_user

        !current_user.sources_dataset.exclude(last_error_id: nil).empty?
      end

      def current_path
        request.path_info
      end

      def nav_current?(path)
        return current_path == "/" if path == "/"

        current_path.start_with?(path)
      end

      def flash_pop
        [session.delete(:flash_notice), session.delete(:flash_error)]
      end

      def flash_notice=(msg)
        session[:flash_notice] = msg
      end

      def flash_error=(msg)
        session[:flash_error] = msg
      end

      def random_username_placeholder
        name = Rewind::LEAD_CHARACTERS.sample
        name.to_s.downcase
            .unicode_normalize(:nfkd)
            .gsub(/[^\x00-\x7f]/, "")
            .gsub(/[^a-z0-9]+/, "-")
            .gsub(/^-+|-+$/, "")
      end

      # Pluralize `singular` for `number`. By default the number is included
      # ("5 days"); pass count: false for just the word ("days"), handy when the
      # number is rendered separately.
      def pluralize(number, singular, plural = nil, count: true)
        word = number == 1 ? singular : (plural || "#{singular}s")
        count ? "#{number} #{word}" : word
      end

      def avatar_letter(user)
        (user.name || user.username).to_s[0, 1].upcase
      end

      def avatar_url(user)
        return unless Rewind::Services::Avatar.path_for(user)

        mtime = File.mtime(Rewind.config.avatar_path(user.id)).to_i
        "/avatars/#{user.id}?v=#{mtime}"
      end

      # A cover image URL, always routed through the local cache proxy so the
      # image is (re)fetched on demand — even for items whose art wasn't stored
      # at sync time. Keyed by the art's owner (the album for its tracks, the
      # item itself otherwise), so everything sharing a cover resolves to one
      # URL and one cached file.
      def poster_url(item, size: "w500")
        owner_type, owner_id = poster_owner(item)
        return "/poster-placeholder.svg" unless owner_id

        token = Base64.urlsafe_encode64("#{owner_type}:#{owner_id}:#{size}",
                                        padding: false)
        "/images/#{token}.jpg"
      end

      # Whether an item has resolvable cover art (a poster owner). Drives the
      # img-vs-gradient-fallback choice on history cover cards.
      def poster?(item)
        !poster_owner(item).nil?
      end

      # [media_type, external_id] of the item that owns the cover art, or nil.
      def poster_owner(item)
        return unless item

        if item.media_type == "track"
          album = item.metadata["album_external_id"].to_s
          return ["album", album] unless album.empty?
        end

        external_id = item.external_id.to_s
        [item.media_type, external_id] unless external_id.empty?
      end

      # The upstream URL for an item's poster, or nil when it has no art.
      # Jellyfin images re-resolve their host from the current source — the host
      # isn't baked into poster_path, so it never goes stale across environments
      # (e.g. a public URL in dev vs an internal docker name in prod).
      def remote_poster_url(item, size = "w185")
        path = item&.poster_path.to_s
        return if path.empty?

        if (jf = jellyfin_image_path(path))
          base = jellyfin_source_url
          return base && "#{base}#{jf}"
        end
        return path if path.start_with?("http://", "https://")

        "https://image.tmdb.org/t/p/#{size}#{path}"
      end

      # The "/Items/<id>/Images/...?tag=..." portion of a Jellyfin image
      # reference (relative or absolute), so its host can be re-resolved from
      # the current source. nil when the path isn't a Jellyfin image.
      def jellyfin_image_path(path)
        idx = path.index("/Items/")
        path[idx..] if idx && path.include?("/Images/")
      end

      # Base URL of a configured Jellyfin source (enabled preferred), or nil.
      def jellyfin_source_url
        url = Rewind::Source.where(type: "jellyfin").exclude(url: nil)
                            .order(Sequel.desc(:enabled)).get(:url)
        url&.sub(%r{/+\z}, "")
      end

      def still_url(path, size: "w300")
        return "/still-placeholder.svg" if path.to_s.empty?
        return path if path.start_with?("http://", "https://")

        "https://image.tmdb.org/t/p/#{size}#{path}"
      end

      # The time element for a history card, or just "Watched" when the play
      # has no recorded date.
      def play_time_html(play)
        return "Watched" unless play.played_at

        %[<time datetime="#{play.played_at.iso8601}">] \
          "#{format_time(play.played_at)}</time>"
      end

      # "Watched Jul 1" status, or just "Watched" without a date.
      def watched_status(play, fmt = "%b %-d")
        return "Watched" unless play.played_at

        "Watched #{in_user_tz(play.played_at).strftime(fmt)}"
      end

      # The dated <time> for a play row on an item page, or "Date unknown".
      def play_date_html(play, fmt = "%a, %b %-d, %Y")
        return "Date unknown" unless play.played_at

        %[<time datetime="#{play.played_at.iso8601}">] \
          "#{in_user_tz(play.played_at).strftime(fmt)}</time>"
      end

      # Formats a "YYYY-MM-DD" date string as "Jul 1, 2026".
      def format_date(value)
        return "" if value.to_s.empty?

        Date.parse(value.to_s).strftime("%b %-d, %Y")
      rescue ArgumentError
        value.to_s
      end

      def in_user_tz(time)
        return unless time

        tz = TZInfo::Timezone.get(current_user&.timezone || "UTC")
        tz.to_local(time.utc)
      rescue TZInfo::InvalidTimezoneIdentifier
        time
      end

      def today_in_user_tz
        in_user_tz(Time.now).to_date
      end

      def format_time(time)
        return "" unless time

        in_user_tz(time).strftime("%-I:%M %p")
      end

      def format_datetime(time, fmt = "%a, %b %-d, %Y %-I:%M %p")
        return "" unless time

        in_user_tz(time).strftime(fmt)
      end

      def day_label(date, today: today_in_user_tz)
        return "Today" if date == today
        return "Yesterday" if date == today - 1

        date.strftime("%A, %B %-d")
      end

      def csrf_tag
        return "" unless env["rack.session"]

        token = env["rack.session"][:csrf]
        %[<input type="hidden" name="authenticity_token" value="#{h(token)}">]
      end

      def media_type_label(type)
        case type
        when "movie" then "Movies"
        when "episode", "series" then "Series"
        when "track", "album", "artist" then "Music"
        else "All"
        end
      end

      def format_runtime(minutes)
        return if minutes.nil? || minutes.to_i.zero?

        mins = minutes.to_i
        h = mins / 60
        m = mins % 60
        return "#{m}m" if h.zero?
        return "#{h}h" if m.zero?

        "#{h}h #{m}m"
      end

      # "3:57" from a track length in milliseconds, or nil when unknown.
      def track_length(ms)
        total = length_seconds(ms)
        return unless total

        "#{total / 60}:#{(total % 60).to_s.rjust(2, '0')}"
      end

      # "PT3M57S" for a <time datetime> from milliseconds, or nil.
      def track_length_iso(ms)
        total = length_seconds(ms)
        return unless total

        "PT#{total / 60}M#{total % 60}S"
      end

      # "42 min" / "1 hr 5 min" album total from summed milliseconds, or nil.
      def album_length(ms)
        total = length_seconds(ms)
        return unless total

        mins = (total / 60.0).round
        hours = mins / 60
        rest = mins % 60
        return "#{mins} min" if hours.zero?

        rest.zero? ? "#{hours} hr" : "#{hours} hr #{rest} min"
      end

      def length_seconds(ms)
        ms = ms.to_i
        return if ms <= 0

        (ms / 1000.0).round
      end

      def directors(item)
        Array(item.credits["crew"])
          .select {|c| c["job"] == "Director" }
          .map {|c| c["name"] }
      end

      def creators(item)
        Array(item.credits["crew"])
          .select {|c| c["job"] == "Creator" }
          .map {|c| c["name"] }
      end

      def top_cast(item, limit = 8)
        Array(item.credits["cast"]).first(limit)
      end

      def tmdb_person_url(person_id)
        "https://www.themoviedb.org/person/#{person_id}"
      end

      # Ratings/reviews for the given plays' items, keyed by item id for the
      # views. Looks them up by the items' stable rating_key underneath (ratings
      # no longer reference item ids), then maps each item id to its rating.
      def load_user_items_for(plays)
        user_items_by_item_id(plays.map(&:item))
      end

      # Ratings for the given items, keyed by item id. Shared by the history
      # cards so track plays and their album group cards both carry a rating.
      def user_items_by_item_id(items)
        items = items.compact
        keys = items.map(&:rating_key).uniq
        return {} if keys.empty?

        rows = UserItem.where(user_id: current_user.id, item_key: keys).all
        by_key = rows.each_with_object({}) {|ui, h| h[ui.item_key] = ui }
        items.each_with_object({}) do |item, result|
          ui = by_key[item.rating_key]
          result[item.id] = ui if ui
        end
      end

      # Builds a /history URL for the given page, preserving the active media
      # type filter. Omits the page param for page 1 to keep URLs clean.
      def history_page_url(page)
        query = {}
        query[:type] = @type if @type && @type != "all"
        query[:page] = page if page > 1
        query.empty? ? "/history" : "/history?#{Rack::Utils.build_query(query)}"
      end

      # The detail line HTML for a history cover card, with links to the item's
      # parents (artist/album for a track, the episode itself for an episode).
      def cover_detail(card)
        case card.kind
        when "track" then track_cover_detail(card)
        when "episode" then episode_cover_detail(card)
        else h(card.movie_year)
        end
      end

      private def track_cover_detail(card)
        parts = []
        if card.item.artist
          parts << item_link(card.artist_item,
                             card.item.artist)
        end
        parts << item_link(card.album_item, card.item.album) if card.item.album
        parts.join(" · ")
      end

      private def episode_cover_detail(card)
        series = item_link(card.show, card.series_name)
        prefix = card.episode_prefix
        prefix ? "#{h(prefix)} — #{series}" : series
      end

      # A link to an item's page, styled to read like body text. Falls back to
      # plain escaped text when the target item is missing.
      def item_link(item, text)
        return h(text) unless item

        %[<a class="content-link" href="/items/#{item.id}">#{h(text)}</a>]
      end

      # Artist-page album sections, grouped by release type in a fixed order.
      # Returns [[heading, albums], …], or nil when no album carries a release
      # type (the plugin that supplies it is optional) — the caller then renders
      # one flat list.
      RELEASE_SECTIONS = [
        %w[album Albums], %w[ep EPs], %w[single Singles],
        %w[compilation Compilations], %w[other Other]
      ].freeze

      def album_type_sections(albums)
        return if albums.none? {|album| album.metadata["release_type"] }

        grouped = albums.group_by do |a|
          release_bucket(a.metadata["release_type"])
        end
        RELEASE_SECTIONS.filter_map do |key, heading|
          list = grouped[key]
          [heading, list] if list && !list.empty?
        end
      end

      # Collapse a raw MusicBrainz release type (which may combine primary and
      # secondary types, e.g. "album compilation") into one display bucket.
      private def release_bucket(type)
        value = type.to_s.downcase
        return "compilation" if value.include?("compilation")
        return "ep" if value.include?("ep")
        return "single" if value.include?("single")
        return "album" if value.include?("album")

        "other"
      end

      def load_music_parents_for(plays)
        ids = plays.flat_map do |p|
          next [] unless p.item.media_type == "track"

          [
            p.item.metadata["artist_external_id"],
            p.item.metadata["album_external_id"]
          ]
        end.compact.uniq
        return {} if ids.empty?

        Item.where(external_id: ids).all.each_with_object({}) do |item, hash|
          hash[item.external_id] = item
        end
      end

      # Loads the plays for a day-paginated window, filtering on the indexed
      # frozen local_date. +days+ is the window's local dates ('YYYY-MM-DD');
      # undated plays (null local_date) are included only when the window
      # reaches the trailing group.
      def plays_for_days(dataset, days, include_undated)
        if days.empty?
          return include_undated ? dataset.where(local_date: nil).all : []
        end

        query = dataset.where(local_date: days)
        query = query.or(local_date: nil) if include_undated
        query.all
      end

      # Folds an ordered play list into display entries, collapsing consecutive
      # track plays from the same album into a single album group. Returns an
      # array of {type: :single, play:} or {type: :album, album_id:, plays:}.
      def group_day_plays(plays)
        entries = plays.each_with_object([]) do |play, acc|
          album_id = play.item.media_type == "track" &&
                     play.item.metadata["album_external_id"]
          last = acc.last
          if album_id && last && last[:type] == :album &&
             last[:album_id] == album_id
            last[:plays] << play
          elsif album_id
            acc << {type: :album, album_id:, plays: [play]}
          else
            acc << {type: :single, play:}
          end
        end
        entries.map do |entry|
          if entry[:type] == :album && entry[:plays].size == 1
            {type: :single, play: entry[:plays].first}
          else
            entry
          end
        end
      end

      def load_shows_for(plays)
        parent_ids = plays.filter_map do |p|
          p.item.media_type == "episode" ? p.item.parent_external_id : nil
        end.uniq
        return {} if parent_ids.empty?

        Item.where(media_type: "series", external_id: parent_ids)
            .all.each_with_object({}) do |show, h|
          h[show.external_id] = show
        end
      end

      def star_svg
        '<svg viewBox="0 0 24 24" stroke-width="1.8" ' \
          'stroke-linejoin="round" aria-hidden="true">' \
          '<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 ' \
          '16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/></svg>'
      end

      def check_svg(size: 13)
        %[<svg width="#{size}" height="#{size}" viewBox="0 0 24 24" ] \
          'fill="none" stroke="currentColor" stroke-width="3" ' \
          'stroke-linecap="round" stroke-linejoin="round" ' \
          'aria-hidden="true"><path d="M5 12l5 5 9-10"/></svg>'
      end

      def plus_svg
        '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" ' \
          'stroke="currentColor" stroke-width="2.5" ' \
          'stroke-linecap="round" aria-hidden="true">' \
          '<path d="M12 5v14M5 12h14"/></svg>'
      end

      def trash_svg
        '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" ' \
          'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' \
          'stroke-linejoin="round" aria-hidden="true">' \
          '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 ' \
          '0 0 2-2l1-12M9 7V4h6v3"/></svg>'
      end
    end
  end
end

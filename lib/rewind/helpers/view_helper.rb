# frozen_string_literal: true

module Rewind
  module Helpers
    module ViewHelper
      def h(value)
        Rack::Utils.escape_html(value.to_s)
      end

      def current_user
        @current_user
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

      def pluralize(count, singular, plural = nil)
        word = count == 1 ? singular : (plural || "#{singular}s")
        "#{count} #{word}"
      end

      def avatar_letter(user)
        (user.name || user.username).to_s[0, 1].upcase
      end

      def avatar_url(user)
        return unless Rewind::Services::Avatar.path_for(user)

        mtime = File.mtime(Rewind.config.avatar_path(user.id)).to_i
        "/avatars/#{user.id}?v=#{mtime}"
      end

      def poster_url(item, size: "w185")
        path = item&.poster_path.to_s
        return "/poster-placeholder.svg" if path.empty?
        return path if path.start_with?("http://", "https://")

        "https://image.tmdb.org/t/p/#{size}#{path}"
      end

      def still_url(path, size: "w300")
        return "/still-placeholder.svg" if path.to_s.empty?

        "https://image.tmdb.org/t/p/#{size}#{path}"
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
        when "episode", "tv" then "TV"
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

      def load_user_items_for(plays)
        ids = plays.map(&:item_id).uniq
        return {} if ids.empty?

        UserItem.where(user_id: current_user.id,
                       item_id: ids).all.each_with_object({}) do |ui, h|
          h[ui.item_id] = ui
        end
      end

      # A link to an item's page, styled to read like body text. Falls back to
      # plain escaped text when the target item is missing.
      def item_link(item, text)
        return h(text) unless item

        %[<a class="content-link" href="/items/#{item.id}">#{h(text)}</a>]
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

        Item.where(media_type: "tv", external_id: parent_ids)
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

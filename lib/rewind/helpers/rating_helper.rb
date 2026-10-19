# frozen_string_literal: true

module Rewind
  module Helpers
    module RatingHelper
      STAR_PATH = '<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 ' \
                  '16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/></svg>'

      STAR_SVG = '<svg viewBox="0 0 24 24" stroke-width="1.8" ' \
                 "stroke-linejoin=\"round\" aria-hidden=\"true\">" \
                 "#{STAR_PATH}".freeze

      THUMB_UP_SVG = '<svg viewBox="0 0 24 24" stroke-width="1.8" ' \
                     'stroke-linecap="round" stroke-linejoin="round" ' \
                     'aria-hidden="true"><path d="M7 10v10H4V10zM7 ' \
                     "10l4-7a2 2 0 0 1 2 2v4h5.5a2 2 0 0 1 2 2.3l-1.3 " \
                     '7a2 2 0 0 1-2 1.7H7"/></svg>'

      THUMB_DOWN_SVG = '<svg viewBox="0 0 24 24" stroke-width="1.8" ' \
                       'stroke-linecap="round" stroke-linejoin="round" ' \
                       'aria-hidden="true"><path d="M7 14V4H4v10zM7 ' \
                       "14l4 7a2 2 0 0 0 2-2v-4h5.5a2 2 0 0 0 " \
                       '2-2.3l-1.3-7a2 2 0 0 0-2-1.7H7"/></svg>'

      def rating_input(item, user_item, user, on_cover: false)
        style = (user || current_user)&.rating_style || "stars"
        current = user_item&.rating
        action = "/items/#{item.id}/rating"
        return thumbs_input(action, current, on_cover:) if style == "thumbs"

        stars_input(action, current, on_cover:)
      end

      def rating_display(user_item, user)
        return "" if user_item.nil? || user_item.rating.nil?

        rating = user_item.rating
        style = (user || current_user)&.rating_style || "stars"
        if style == "thumbs"
          svg = rating >= 3 ? THUMB_UP_SVG : THUMB_DOWN_SVG
          cls = rating >= 3 ? "is-on" : "is-off"
          label = rating >= 3 ? "Thumbs up" : "Thumbs down"
          return %[<span class="rating-readout__thumb #{cls}" ] +
                 %[aria-label="#{label}">#{svg}</span>]
        end

        empty = "★" * (5 - rating)
        ("★" * rating) + %[<span class="stars__empty">#{empty}</span>]
      end

      def rating_readout(user_item, user)
        return "" if user_item.nil? || user_item.rating.nil?

        rating = user_item.rating
        style = (user || current_user)&.rating_style || "stars"
        if style == "thumbs"
          up = rating >= 3
          svg = up ? THUMB_UP_SVG : THUMB_DOWN_SVG
          <<~HTML
            <div class="rating-readout">
              <span>Your rating</span>
              <span class="rating-readout__thumb #{up ? 'is-up' : 'is-down'}">#{svg}</span>
            </div>
          HTML
        else
          stars = (1..5).map do |n|
            on = "is-on" if n <= rating
            attrs = %[class="#{on}" viewBox="0 0 24 24" stroke-width="1.8" ]
            %[<svg #{attrs}stroke-linejoin="round" ] \
              "aria-hidden=\"true\">#{STAR_PATH}"
          end.join
          <<~HTML
            <div class="rating-readout">
              <span>Your rating</span>
              <span class="rating-readout__stars" role="img" aria-label="Rated #{rating} of 5">#{stars}</span>
            </div>
          HTML
        end
      end

      private def stars_input(action, current, on_cover: false)
        current ||= 0
        buttons = (1..5).map do |value|
          on = value <= current
          cls = on ? ' class="is-on"' : ""
          pressed = current == value ? ' aria-pressed="true"' : ""
          plural = "s" unless value == 1
          %[<button#{cls} name="rating" value="#{value}" ] +
            %[aria-label="#{value} star#{plural}"#{pressed}>] +
            %[#{STAR_SVG}</button>]
        end.join
        <<~HTML
          <form class="stars#{' on-cover' if on_cover}" method="post" action="#{action}" aria-label="Rate">
            #{csrf_tag}
            #{buttons}
          </form>
        HTML
      end

      private def thumbs_input(action, current, on_cover: false)
        up_pressed = current && current >= 3
        down_pressed = current && current < 3
        <<~HTML
          <form class="thumbs#{' on-cover' if on_cover}" method="post" action="#{action}" aria-label="Rate">
            #{csrf_tag}
            <button name="rating" value="up" aria-label="Thumbs up" aria-pressed="#{up_pressed}">#{THUMB_UP_SVG}</button>
            <button name="rating" value="down" aria-label="Thumbs down" aria-pressed="#{down_pressed}">#{THUMB_DOWN_SVG}</button>
          </form>
        HTML
      end
    end
  end
end

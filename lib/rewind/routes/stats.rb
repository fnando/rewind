# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/stats" do
      @media_type = params[:type] || "all"
      @period = params[:period] || "year"
      @from, @to = Services::Stats.resolve_period(
        @period,
        params[:from],
        params[:to]
      )

      @stats = Services::Stats.new(
        user: current_user,
        media_type: @media_type,
        from: @from,
        to: @to,
        period: @period
      ).to_h

      @streaks = Services::Streaks.new(user: current_user).get_streaks

      erb :"stats/index"
    end
  end
end

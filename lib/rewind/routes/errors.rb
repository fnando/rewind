# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    ERRORS_PER_PAGE = 50

    get "/settings/errors" do
      require_admin!
      @page = [params[:page].to_i, 1].max
      offset = (@page - 1) * ERRORS_PER_PAGE
      scope = ErrorLog.order(Sequel.desc(:created_at), Sequel.desc(:id))
      @total = scope.count
      @errors = scope.limit(ERRORS_PER_PAGE).offset(offset).all
      @has_prev = @page > 1
      @has_next = offset + @errors.size < @total
      erb :"settings/errors/index"
    end

    get "/settings/errors/:id" do
      require_admin!
      @error = ErrorLog[params[:id].to_i]
      halt 404 unless @error
      erb :"settings/errors/show"
    end
  end
end

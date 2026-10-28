# frozen_string_literal: true

require "json"

module Rewind
  # One captured error — class, message, full backtrace, and the data that
  # caused it (request/sync context). Written by the web error handler and the
  # sync rescue; read by the admin error page.
  class ErrorLog < Sequel::Model
    # Persist an exception. Never raises: a logging failure must not mask the
    # original error, so any problem here is swallowed and logged.
    def self.record(exception, context: {})
      create(
        error_class: exception.class.name,
        message: exception.message.to_s,
        backtrace: Array(exception.backtrace).join("\n"),
        context_json: blank?(context) ? nil : JSON.generate(context)
      )
    rescue StandardError => error
      Rewind.logger.error("[error_log] failed to persist: #{error.class}: " \
                          "#{error.message}")
      nil
    end

    def self.blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    # The decoded causing-data hash ({} when none/unparsable).
    def context
      return {} if context_json.nil? || context_json.empty?

      @context ||= JSON.parse(context_json)
    rescue JSON::ParserError
      {}
    end

    # The backtrace as an array of frames (empty when none).
    def backtrace_lines
      backtrace.to_s.split("\n")
    end

    # A one-line summary for the list ("RuntimeError: boom").
    def summary
      "#{error_class}: #{message}"
    end
  end
end

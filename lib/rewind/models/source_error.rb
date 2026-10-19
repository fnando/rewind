# frozen_string_literal: true

module Rewind
  # A single recorded sync failure for a source. Kept as a log so a resolved
  # error stays viewable ("See previous error") after the next sync clears the
  # source's current-error pointer.
  class SourceError < Sequel::Model
    many_to_one :source
  end
end

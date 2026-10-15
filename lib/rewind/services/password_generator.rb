# frozen_string_literal: true

module Rewind
  module Services
    module PasswordGenerator
      ADJECTIVES = %w[
        brave calm clever crisp eager fair golden happy jolly kind
        lively merry noble proud quick quiet rapid silver swift witty zesty
      ].freeze

      NOUNS = %w[
        otter badger falcon panda hawk tiger wolf lynx heron fox
        raven eagle lion ocelot koala bison dolphin crane heron sparrow
      ].freeze

      def self.call
        "#{ADJECTIVES.sample}-#{NOUNS.sample}-#{SecureRandom.random_number(10_000).to_s.rjust(4, "0")}"
      end
    end
  end
end

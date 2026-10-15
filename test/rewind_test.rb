# frozen_string_literal: true

require "test_helper"

class RewindTest < Minitest::Test
  test "has a version" do
    assert_match(/\A\d+\.\d+\.\d+\z/, Rewind::VERSION)
  end
end

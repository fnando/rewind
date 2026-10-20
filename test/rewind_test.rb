# frozen_string_literal: true

require "test_helper"

class RewindTest < Minitest::Test
  test "has a version" do
    assert_match(/\A\d+\.\d+\.\d+\z/, Rewind::VERSION)
  end

  test "format_duration scales the unit to the elapsed time" do
    assert_equal "843ms", Rewind.format_duration(0.843)
    assert_equal "4.2s", Rewind.format_duration(4.23)
    assert_equal "1m12s", Rewind.format_duration(72)
  end
end

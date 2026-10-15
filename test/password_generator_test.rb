# frozen_string_literal: true

require "test_helper"

class PasswordGeneratorTest < Minitest::Test
  test "produces readable adjective-noun-digits string" do
    pw = Rewind::Services::PasswordGenerator.call
    assert_match(/\A[a-z]+-[a-z]+-\d{4}\z/, pw)
  end

  test "produces different passwords each call" do
    passwords = Array.new(10) { Rewind::Services::PasswordGenerator.call }
    assert passwords.uniq.size > 1
  end
end

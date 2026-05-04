# frozen_string_literal: true
require "test_helper"

class TestConformanceBridgeSkeleton < Test::Unit::TestCase
  def test_register_and_lookup_handler_table
    handlers = { generate: ->(ctx) { "ok:#{ctx}" } }
    table_handle = AppleSDKMacRuntime.conformance_register_handlers(handlers)
    assert table_handle > 0
    AppleSDKMacRuntime.conformance_release_handlers(table_handle)
  end
end

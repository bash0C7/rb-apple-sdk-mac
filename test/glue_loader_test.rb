# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_loader"
require "apple_sdk_mac/glue_compiler/swiftc_invoker"

class TestGlueLoader < Test::Unit::TestCase
  def test_loads_a_minimal_glue_and_invokes_it
    Dir.mktmpdir do |dir|
      src = File.join(dir, "g.swift")
      dylib = File.join(dir, "g.dylib")
      File.write(src, <<~SWIFT)
        import Foundation
        @c public func glue_minimal_passthrough(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
            return argv[0]
        }
      SWIFT
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      assert ok, err
      loader = AppleSDKMac::GlueLoader.new
      ptr = loader.load(dylib_path: dylib, exported_symbol: "glue_minimal_passthrough")
      result = loader.invoke(ptr, [42])
      assert_equal 42, result
    end
  end
end

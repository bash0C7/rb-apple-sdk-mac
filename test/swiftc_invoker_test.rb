# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_compiler/swiftc_invoker"

class TestSwiftcInvoker < Test::Unit::TestCase
  def test_compiles_minimal_swift_source_to_dylib
    Dir.mktmpdir do |dir|
      src = File.join(dir, "x.swift")
      File.write(src, <<~SWIFT)
        import Foundation
        @c public func glue_x(_ a: Int) -> Int { a + 1 }
      SWIFT
      dylib = File.join(dir, "x.dylib")
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      assert ok, "swiftc failed: #{err}"
      assert File.exist?(dylib)
    end
  end

  def test_reports_compile_errors
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.swift")
      File.write(src, "this is not valid swift")
      dylib = File.join(dir, "broken.dylib")
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      refute ok
      assert err.length > 0
    end
  end
end

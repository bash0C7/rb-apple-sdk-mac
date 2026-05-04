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

  def test_passes_module_search_paths_as_dash_I
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "fake-swiftc")
      log = File.join(dir, "argv.log")
      File.write(fake, <<~SH)
        #!/bin/sh
        printf '%s\\0' "$@" > #{log}
        exit 0
      SH
      File.chmod(0o755, fake)

      src = File.join(dir, "x.swift"); File.write(src, "")
      dylib = File.join(dir, "x.dylib")

      AppleSDKMac::GlueCompiler::SwiftcInvoker.new(swiftc: fake).compile(
        source_path: src,
        dylib_path: dylib,
        module_search_paths: ["/some/Modules", "/another/Modules"]
      )

      argv = File.read(log).split("\0")
      pairs = argv.each_cons(2).to_a
      assert(pairs.any? { |a, b| a == "-I" && b == "/some/Modules" },
             "expected -I /some/Modules in argv: #{argv.inspect}")
      assert(pairs.any? { |a, b| a == "-I" && b == "/another/Modules" },
             "expected -I /another/Modules in argv: #{argv.inspect}")
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

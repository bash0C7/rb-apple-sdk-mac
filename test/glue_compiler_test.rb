# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "apple_sdk_mac/glue_compiler"
require "apple_sdk_mac/compiled_glue_cache"

class TestGlueCompiler < Test::Unit::TestCase
  class StubSwiftc
    def compile(source_path:, dylib_path:, runtime_dylib_path: nil, link_libs: [], module_search_paths: [])
      File.write(dylib_path, "")
      [true, ""]
    end
  end

  def test_compile_simple_c_function_uses_template_path
    Dir.mktmpdir do |dir|
      cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
      sym = {
        name: "MIDIClientDispose",
        kind: "function", abi: "c",
        signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
        parameters_json: JSON.dump([{ "name" => "client", "type" => "MIDIClientRef" }])
      }
      compiler = AppleSDKMac::GlueCompiler.new(
        cache: cache,
        runtime_dylib_path: nil,
        swiftc_invoker: StubSwiftc.new
      )
      result = compiler.compile(framework: "CoreMIDI", symbol: sym)
      assert result.success?, result.error_detail
      assert_equal "template", result.generator
      cache.close
    end
  end
end

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

  def test_glue_id_changes_when_parameters_json_changes
    Dir.mktmpdir do |dir|
      cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
      compiler = AppleSDKMac::GlueCompiler.new(
        cache: cache, runtime_dylib_path: "/dev/null",
        swiftc_invoker: StubSwiftc.new
      )
      sym1 = { name: "F", signature: "void F(int)", parameters_json: '[{"name":"x","kind":"int"}]' }
      sym2 = { name: "F", signature: "void F(int)", parameters_json: '[{"name":"y","kind":"int"}]' }

      id1 = compiler.send(:compute_glue_id, "X", sym1)
      id2 = compiler.send(:compute_glue_id, "X", sym2)
      assert_not_equal id1, id2,
        "compute_glue_id must include parameters_json so cached glue invalidates when metadata shape changes"
      cache.close
    end
  end
end

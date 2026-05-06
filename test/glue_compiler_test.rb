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
        parameters_json: JSON.dump([{ "name" => "client", "type" => "MIDIClientRef",
                                       "kind" => "opaque_ref", "is_out_param" => false,
                                       "nullability" => "unspecified" }])
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

  class CountingLLM
    attr_reader :call_count
    def initialize
      @call_count = 0
    end
    def generate(framework:, symbol:, glue_id:)
      @call_count += 1
      nil
    end
    def close; end
  end

  def test_max_llm_retries_default_compensates_for_foundation_model_non_determinism
    assert_operator AppleSDKMac::GlueCompiler::DEFAULT_MAX_LLM_RETRIES, :>, 3,
      "Default LLM retry budget must be > 3. Spec verification (2026-05-05) " \
      "showed Foundation Model on-device produces ~1/3 off-format responses; " \
      "a budget of 3 burns the entire allowance before any well-formed retry " \
      "has a chance to land."
  end

  # T40 — exported_symbol sanitize. canonical_name "NSString.stringWithUTF8String"
  # は Swift identifier として無効（dot 含む）。glue_compiler は機械的に
  # `gsub(/[^A-Za-z0-9_]/, "_")` で swift_identifier 化する必要がある（spec §3.2）。
  class FakeTemplate
    def generate(framework:, symbol:, glue_id:)
      # 最小限の Swift スタブ。exported_symbol が Swift-safe であることを
      # template が前提にできるよう、ここは sanitize 済み identifier を埋める。
      ident = symbol[:name].gsub(/[^A-Za-z0-9_]/, "_")
      <<~SWIFT
        @c
        public func glue_#{glue_id}_#{ident}(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            return 4
        }
      SWIFT
    end
  end

  def test_exported_symbol_is_sanitized_when_symbol_name_contains_dot
    Dir.mktmpdir do |dir|
      cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
      sym = {
        name: "NSString.stringWithUTF8String",
        kind: "objc_method_class", abi: nil,
        signature: nil, parameters_json: "[]"
      }
      compiler = AppleSDKMac::GlueCompiler.new(
        cache: cache, runtime_dylib_path: nil,
        swiftc_invoker: StubSwiftc.new
      )
      compiler.instance_variable_set(:@template, FakeTemplate.new)
      result = compiler.compile(framework: "Foundation", symbol: sym)
      assert result.success?, "stub template + StubSwiftc should compile clean: #{result.error_detail}"
      assert_match(/\Aglue_[a-f0-9]+_NSString_stringWithUTF8String\z/, result.exported_symbol,
        "T40: exported_symbol must sanitize non-identifier chars (got: #{result.exported_symbol.inspect})")
      cache.close
    end
  end

  def test_max_llm_retries_is_configurable_via_constructor_kwarg
    Dir.mktmpdir do |dir|
      cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
      llm = CountingLLM.new
      compiler = AppleSDKMac::GlueCompiler.new(
        cache: cache, runtime_dylib_path: "/dev/null",
        llm_generator: llm, swiftc_invoker: StubSwiftc.new,
        max_llm_retries: 7
      )
      # abi:"swift" routes to llm_path because template_generator returns nil
      # for non-c abi (template_generator.rb:36).
      sym = {
        name: "asyncFetchTitle", kind: "function", abi: "swift",
        signature: "func asyncFetchTitle() -> String", parameters_json: "[]"
      }
      result = compiler.compile(framework: "AcmeFW", symbol: sym)
      refute result.success?, "LLM stub returns nil; compile must fail after exhausting retries"
      assert_equal 7, llm.call_count,
        "GlueCompiler must invoke LLM exactly max_llm_retries (=7) times " \
        "before declaring exhaustion. Hard-coded constant would only call 3 times."
      cache.close
    end
  end
end

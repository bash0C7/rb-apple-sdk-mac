# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/dispatcher"

class TestDispatcher < Test::Unit::TestCase
  class FakeKnowledge
    def lookup_symbol(framework:, symbol:)
      return nil if symbol == "Missing"
      { name: symbol, kind: "function", abi: "c", content_hash: "h" }
    end
  end

  class FakeCache
    def initialize; @hits = {}; end
    def lookup(framework:, symbol:); @hits[[framework, symbol]]; end
    def fake_hit!(framework, symbol, exported, dylib)
      @hits[[framework, symbol]] = {
        glue_id: "g", dylib_path: dylib, exported_symbol: exported, generator: "template"
      }
    end
  end

  class FakeLoader
    attr_reader :calls
    def initialize; @calls = []; end
    def load(dylib_path:, exported_symbol:); @calls << [dylib_path, exported_symbol]; 0xCAFE; end
    def invoke(fn_ptr, args); ["invoked", fn_ptr, args]; end
  end

  def test_dispatch_uses_cache_hit
    cache = FakeCache.new
    cache.fake_hit!("CoreMIDI", "MIDIDispose", "glue_g_MIDIDispose", "/tmp/g.dylib")
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: nil
    )
    result = d.dispatch(framework: "CoreMIDI", symbol: "MIDIDispose", args: [42])
    assert_equal ["invoked", 0xCAFE, [42]], result
    assert_equal [["/tmp/g.dylib", "glue_g_MIDIDispose"]], loader.calls
  end

  # T40 — dispatcher は cache.lookup を **sym_meta[:name] = canonical_name** 経由で
  # 行う必要がある（spec §3.2 / G5）。user-facing symbol arg と canonical_name が
  # 一致しないケース（user が KB の alias を渡した、selector colon の有無、等）
  # でも cache hit を取れる contract をピン止めする。
  class FakeKnowledgeCanonical
    def lookup_symbol(framework:, symbol:)
      # user passed "alias_name" but canonical name in synth/DB is "NSString.stringWithUTF8String"
      { name: "NSString.stringWithUTF8String", kind: "objc_method_class" }
    end
  end

  def test_dispatch_uses_sym_meta_name_for_cache_lookup
    cache = FakeCache.new
    cache.fake_hit!("Foundation", "NSString.stringWithUTF8String",
                     "glue_g_NSString_stringWithUTF8String", "/tmp/g.dylib")
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledgeCanonical.new, glue_cache: cache,
      loader: loader, compiler: nil
    )
    # user-facing symbol differs from canonical, but dispatcher must route cache
    # lookup via sym_meta[:name] (canonical) so the cache hit lands.
    result = d.dispatch(framework: "Foundation", symbol: "alias_name", args: [])
    assert_equal ["invoked", 0xCAFE, []], result
    assert_equal [["/tmp/g.dylib", "glue_g_NSString_stringWithUTF8String"]], loader.calls
  end

  def test_dispatch_raises_on_unknown_symbol
    cache = FakeCache.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: FakeLoader.new, compiler: nil
    )
    assert_raise(AppleSDKMac::Error) do
      d.dispatch(framework: "CoreMIDI", symbol: "Missing", args: [])
    end
  end

  # Transparent auto-discover (2026-05-08): when KB has the symbol record
  # but the glue is not yet compiled, Dispatcher must trigger compile +
  # cache populate inline so the call succeeds without an upfront
  # `Apple.discover` from the user.
  class FakeCompilerThatPopulatesCache
    def initialize(cache); @cache = cache; @calls = []; end
    attr_reader :calls
    def compile(framework:, symbol:)
      @calls << [framework, symbol[:name]]
      @cache.fake_hit!(framework, symbol[:name],
                       "glue_auto_#{symbol[:name]}", "/tmp/auto.dylib")
      Struct.new(:success?, :error_stage, :error_detail).new(true, nil, nil)
    end
  end

  class FakeCompilerThatFails
    def compile(framework:, symbol:)
      Struct.new(:success?, :error_stage, :error_detail).new(false, "swiftc", "fake fail")
    end
  end

  def test_dispatch_auto_compiles_on_cache_miss_when_kb_has_symbol
    cache = FakeCache.new
    compiler = FakeCompilerThatPopulatesCache.new(cache)
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: compiler
    )
    # No fake_hit! before dispatch — cache miss path. Must not raise.
    result = d.dispatch(framework: "CoreMIDI", symbol: "MIDIClientCreate", args: [1, 2])
    assert_equal ["invoked", 0xCAFE, [1, 2]], result
    assert_equal [["CoreMIDI", "MIDIClientCreate"]], compiler.calls,
                 "compiler.compile should be invoked exactly once for the missing glue"
    assert_equal [["/tmp/auto.dylib", "glue_auto_MIDIClientCreate"]], loader.calls
  end

  def test_dispatch_raises_when_auto_compile_fails
    cache = FakeCache.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: FakeLoader.new, compiler: FakeCompilerThatFails.new
    )
    assert_raise(AppleSDKMac::Error) do
      d.dispatch(framework: "CoreMIDI", symbol: "MIDIClientCreate", args: [])
    end
  end
end

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
end

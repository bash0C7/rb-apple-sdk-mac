# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac/errors"
require "apple_sdk_mac/dispatcher"

class TestDispatcherPhase2Diagnostics < Test::Unit::TestCase
  class FakeKnowledgeCache
    def initialize(records = {})
      @records = records
    end

    def lookup_symbol(framework:, symbol:)
      @records[[framework, symbol]]
    end
  end

  class FakeGlueCache
    def initialize(hits = {})
      @hits = hits
    end

    def lookup(framework:, symbol:)
      @hits[[framework, symbol]]
    end
  end

  class FakeLoader
    def load(dylib_path:, exported_symbol:)
      :fake_fn_ptr
    end

    def invoke(fn_ptr, args)
      :invoked
    end
  end

  class FakeCompiler
    def initialize(behavior)
      @behavior = behavior
    end

    def compile(framework:, symbol:)
      case @behavior
      when :unsupported
        raise AppleSDKMac::UnsupportedPatternError.new(
          pattern: "swift_macro",
          framework: framework,
          symbol: symbol[:name].to_s
        )
      when :fail
        # compile fails silently — cache stays empty
        nil
      when :success
        # caller will see @cache.lookup hit thanks to test fixture
        :compiled
      end
    end
  end

  def test_dispatcher_raises_symbol_missing_when_kb_lookup_returns_nil
    kc = FakeKnowledgeCache.new({})  # empty store
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc,
      glue_cache: FakeGlueCache.new,
      loader: FakeLoader.new,
      compiler: FakeCompiler.new(:success)
    )
    err = assert_raise(AppleSDKMac::SymbolMissingError) do
      d.dispatch(framework: "Foundation", symbol: "NoSuchAPI", args: [])
    end
    assert_match(/Foundation/, err.message)
    assert_match(/NoSuchAPI/, err.message)
  end

  def test_dispatcher_raises_glue_compile_error_when_compile_fails_silent
    kc = FakeKnowledgeCache.new(
      ["Foundation", "BadAPI"] => { name: "BadAPI" }
    )
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc,
      glue_cache: FakeGlueCache.new,  # cache miss
      loader: FakeLoader.new,
      compiler: FakeCompiler.new(:fail)  # compile no-op、 cache 依然空
    )
    err = assert_raise(AppleSDKMac::GlueCompileError) do
      d.dispatch(framework: "Foundation", symbol: "BadAPI", args: [])
    end
    assert_match(/BadAPI/, err.message)
  end

  def test_dispatcher_propagates_unsupported_pattern_error_from_compiler
    kc = FakeKnowledgeCache.new(
      ["Foundation", "Observable.someMethod"] => { name: "Observable.someMethod" }
    )
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc,
      glue_cache: FakeGlueCache.new,  # cache miss
      loader: FakeLoader.new,
      compiler: FakeCompiler.new(:unsupported)
    )
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      d.dispatch(framework: "Foundation", symbol: "Observable.someMethod", args: [])
    end
    assert_equal "swift_macro", err.pattern
  end
end

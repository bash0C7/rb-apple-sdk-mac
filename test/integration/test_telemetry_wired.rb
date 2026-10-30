# frozen_string_literal: true
require "test/unit"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/dispatcher"
require_relative "../../lib/apple_sdk_mac/glue_compiler"
require_relative "../../lib/apple_sdk_mac/telemetry"

class TestTelemetryWired < Test::Unit::TestCase
  class FakeKnowledgeCache
    def initialize(symbol_data: nil)
      @symbol = symbol_data
    end

    def lookup_symbol(framework:, symbol:)
      @symbol
    end
  end

  class FakeGlueCache
    attr_reader :base_dir, :sdk_version
    def initialize(dir)
      @base_dir = dir
      @sdk_version = "26.0"
    end

    def lookup(framework:, symbol:)
      nil
    end

    def record_attempt(**_kwargs); end
    def insert(**_kwargs); end
    def find(*); nil; end
  end

  class FakeCompilerSilentFail
    def compile(framework:, symbol:)
      nil
    end
  end

  class FakeCompilerUnsupported
    def compile(framework:, symbol:)
      raise AppleSDKMac::UnsupportedPatternError.new(
        pattern: "swift_macro",
        framework: framework,
        symbol: symbol[:name]
      )
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("telemetry_wired")
    @diag = Dir.mktmpdir("diag")
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = @diag
    ENV.delete("APPLE_SDK_MAC_NO_DIAGNOSTICS")
  end

  def teardown
    ENV.delete("APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    FileUtils.rm_rf(@diag) if @diag
  end

  def jsonl_lines
    path = File.join(@diag, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  def test_symbol_missing_raise_emits_telemetry
    kc = FakeKnowledgeCache.new(symbol_data: nil)
    gc = FakeGlueCache.new(@tmpdir)
    dispatcher = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc, glue_cache: gc,
      compiler: nil, loader: nil
    )
    assert_raise(AppleSDKMac::SymbolMissingError) do
      dispatcher.dispatch(framework: "Foundation", symbol: "no_such")
    end
    events = jsonl_lines
    assert_equal 1, events.size
    assert_equal "symbol_missing", events[0]["stage"]
    assert_equal "Foundation",     events[0]["framework"]
    assert_equal "no_such",        events[0]["symbol"]
  end

  def test_unsupported_pattern_raise_emits_telemetry
    kc = FakeKnowledgeCache.new(symbol_data: { name: "x", kind: "swift_func" })
    gc = FakeGlueCache.new(@tmpdir)
    compiler = FakeCompilerUnsupported.new
    dispatcher = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc, glue_cache: gc,
      compiler: compiler, loader: nil
    )
    assert_raise(AppleSDKMac::UnsupportedPatternError) do
      dispatcher.dispatch(framework: "Foundation", symbol: "x")
    end
    events = jsonl_lines
    assert_equal 1, events.size
    assert_equal "unsupported_pattern", events[0]["stage"]
    assert_equal "swift_macro",         events[0]["detail"]
    assert_equal "Foundation",          events[0]["framework"]
    assert_equal "x",                   events[0]["symbol"]
  end

  def test_compile_failed_raise_emits_telemetry
    kc = FakeKnowledgeCache.new(symbol_data: { name: "y", kind: "swift_func" })
    gc = FakeGlueCache.new(@tmpdir)
    compiler = FakeCompilerSilentFail.new
    dispatcher = AppleSDKMac::Dispatcher.new(
      knowledge_cache: kc, glue_cache: gc,
      compiler: compiler, loader: nil
    )
    assert_raise(AppleSDKMac::GlueCompileError) do
      dispatcher.dispatch(framework: "Foundation", symbol: "y")
    end
    events = jsonl_lines
    assert_equal 1, events.size
    assert_equal "compile_failed", events[0]["stage"]
    assert_equal "Foundation",     events[0]["framework"]
    assert_equal "y",              events[0]["symbol"]
  end
end

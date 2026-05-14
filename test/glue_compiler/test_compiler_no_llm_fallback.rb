# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require "apple_sdk_mac/glue_compiler"

class TestGlueCompilerNoLLMFallback < Test::Unit::TestCase
  class FakeCache
    attr_reader :base_dir, :sdk_version, :attempts, :inserts
    def initialize(base_dir)
      @base_dir = base_dir
      @sdk_version = "26.0"
      @attempts = []
      @inserts = []
      FileUtils.mkdir_p(File.join(base_dir, "26.0", "sources"))
      FileUtils.mkdir_p(File.join(base_dir, "26.0", "lib"))
    end
    def record_attempt(**kwargs); @attempts << kwargs; end
    def insert(**kwargs); @inserts << kwargs; end
  end

  class FakeTemplate
    def initialize(source) ; @source = source ; end
    def generate(**_kwargs) ; @source ; end
  end

  class FakeGates
    Pass = Struct.new(:pass?, :errors)
    def initialize(pass:) ; @pass = pass ; end
    def validate(*_) ; @pass ? Pass.new(true, []) : Pass.new(false, ["forced gate fail"]) ; end
  end

  class FakeSwiftc
    def initialize(success:) ; @success = success ; end
    def compile(**_kwargs)
      @success ? [true, nil] : [false, "forced swiftc fail"]
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("glue_compiler_no_llm")
    @cache = FakeCache.new(@tmpdir)
    @symbol = { name: "fooBar", signature: "void fooBar(void)", parameters_json: "[]" }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_compile_returns_template_failure_directly_when_gate_fails
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: @cache,
      runtime_dylib_path: "/dev/null",
      template_generator: FakeTemplate.new("dummy swift"),
    )
    compiler.instance_variable_set(:@gates, FakeGates.new(pass: false))
    compiler.instance_variable_set(:@swiftc, FakeSwiftc.new(success: true))

    result = compiler.compile(framework: "Foundation", symbol: @symbol)

    assert_equal false, result.success?
    assert_equal "static_check", result.error_stage
    assert_match(/forced gate fail/, result.error_detail)
    assert_equal 1, @cache.attempts.size,
      "compile() must not retry via LLM after template failure (Phase 3 invariant)"
    assert_equal "template", @cache.attempts.first[:generator]
  end

  def test_compile_returns_template_failure_directly_when_swiftc_fails
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: @cache,
      runtime_dylib_path: "/dev/null",
      template_generator: FakeTemplate.new("import Foundation\n"),
    )
    compiler.instance_variable_set(:@gates, FakeGates.new(pass: true))
    compiler.instance_variable_set(:@swiftc, FakeSwiftc.new(success: false))

    result = compiler.compile(framework: "Foundation", symbol: @symbol)

    assert_equal false, result.success?
    assert_equal "swiftc", result.error_stage
    assert_match(/forced swiftc fail/, result.error_detail)
    assert_equal 1, @cache.attempts.size
    assert_equal "template", @cache.attempts.first[:generator]
  end

  def test_compile_constructor_rejects_llm_kwargs
    assert_raise(ArgumentError) do
      AppleSDKMac::GlueCompiler.new(
        cache: @cache,
        runtime_dylib_path: "/dev/null",
        llm_generator: :something,
      )
    end
  end
end

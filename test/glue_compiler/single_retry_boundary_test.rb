require "test/unit"
require "fileutils"
require "tmpdir"
require "apple_sdk_mac/glue_compiler"

class SingleRetryBoundaryTest < Test::Unit::TestCase
  class FakeTemplate
    attr_reader :calls
    def initialize; @calls = 0; end
    def generate(framework:, symbol:, glue_id:)
      @calls += 1
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      # Returns source that passes gate validation but will fail swiftc compilation
      "@c public func glue_#{glue_id}_#{swift_id}(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { THIS_IS_INVALID_SWIFT }"
    end
  end

  class FakeLLM
    attr_reader :calls
    def initialize; @calls = 0; end
    def generate(framework:, symbol:, glue_id:)
      @calls += 1
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      "@c public func glue_#{glue_id}_#{swift_id}(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { return 0 }"
    end
  end

  class FakeSwiftc
    def initialize(template_ok:, llm_ok:); @t = template_ok; @l = llm_ok; @phase = :template; end
    def compile(source_path:, dylib_path:, runtime_dylib_path: nil, module_search_paths: [])
      ok = @phase == :template ? @t : @l
      @phase = :llm
      [ok, ok ? nil : "fake swiftc error"]
    end
  end

  class FakeCache
    attr_reader :inserts
    def initialize(base_dir, sdk_version); @base_dir, @sdk_version = base_dir, sdk_version; @inserts = []; end
    def base_dir; @base_dir; end
    def sdk_version; @sdk_version; end
    def insert(**row); @inserts << row; end
    def record_attempt(**row); end
  end

  def test_template_swiftc_failure_falls_through_to_llm
    Dir.mktmpdir do |dir|
      cache = FakeCache.new(dir, "26.2")
      FileUtils.mkdir_p(File.join(dir, "26.2", "sources"))
      FileUtils.mkdir_p(File.join(dir, "26.2", "lib"))
      template = FakeTemplate.new
      llm = FakeLLM.new
      compiler = AppleSDKMac::GlueCompiler.new(
        cache: cache, runtime_dylib_path: nil, runtime_modules_paths: [],
        template_generator: template,
        llm_generator: llm, swiftc_invoker: FakeSwiftc.new(template_ok: false, llm_ok: true)
      )

      sym = { name: "FAKE", kind: "function", abi: "c", signature: "void FAKE()", parameters_json: "[]" }
      result = compiler.compile(framework: "Fake", symbol: sym)

      assert result.success?, "expected template→LLM fallback success, got #{result.error_stage}: #{result.error_detail}"
      assert_equal 1, template.calls, "template should be called exactly once"
      assert_equal 1, llm.calls, "llm should be called once after template swiftc fail"
      assert_equal "llm", cache.inserts.first[:generator]
    end
  end
end

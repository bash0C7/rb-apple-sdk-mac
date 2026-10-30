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

  class FakeTemplate
    def generate(framework:, symbol:, glue_id:)
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
        "exported_symbol must sanitize non-identifier chars (got: #{result.exported_symbol.inspect})")
      cache.close
    end
  end
end

class GlueCompilerCoverageBoundaryTest < Test::Unit::TestCase
  def test_out_of_coverage_raises_when_backend_none
    fake_template = Object.new
    def fake_template.generate(**) = nil
    cache = make_fake_cache
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template,
      inference_backend: nil
    )
    sym = { name: "WeirdMacro", kind: "swift_macro", abi: "swift",
            signature: "()", parameters_json: "[]" }
    assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "Foo", symbol: sym)
    end
  end

  def test_in_coverage_template_nil_returns_failed_result_not_raise
    fake_template = Object.new
    def fake_template.generate(**) = nil
    cache = make_fake_cache
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, inference_backend: nil
    )
    sym = { name: "AudioObjectGetPropertyDataSize", kind: "function", abi: "c",
            signature: "()",
            parameters_json: JSON.generate([{ "type" => "UInt32*", "is_out_param" => true, "kind" => "int" }]) }
    result = compiler.compile(framework: "CoreAudio", symbol: sym)
    assert_false result.success?
    assert_equal "template_nil", result.error_stage
  end

  private

  def make_fake_cache
    cache = Object.new
    def cache.base_dir = "/tmp"
    def cache.sdk_version = "26.5"
    def cache.record_attempt(**) = nil
    cache
  end
end

class GlueCompilerInferenceTest < Test::Unit::TestCase
  def test_inference_success_inserts_with_inference_generator
    inserted = {}
    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**kw| inserted.replace(kw) }

    fake_template = Object.new
    def fake_template.generate(**) = nil

    gates = Object.new
    def gates.validate(*, **) = Struct.new(:pass?, :errors).new(true, [])
    swiftc = Object.new
    def swiftc.compile(dylib_path:, **)
      File.write(dylib_path, "")
      [true, nil]
    end

    backend = Object.new
    def backend.name = "claude_p"
    def backend.generate_glue(**) = AppleSDKMac::Inference::BackendResult.new(swift_source: "@c public func glue_x_Sym() {}")

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, gates: gates, swiftc_invoker: swiftc,
      inference_backend: backend
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()",
            parameters_json: "[]" }
    result = compiler.compile(framework: "F", symbol: sym)
    assert_true result.success?
    assert_equal "inference:claude_p", result.generator
    assert_equal "inference:claude_p", inserted[:generator]
  end

  def test_inference_nil_raises_out_of_coverage
    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    fake_template = Object.new
    def fake_template.generate(**) = nil
    backend = Object.new
    def backend.name = "claude_p"
    def backend.generate_glue(**) = nil

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, inference_backend: backend
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()",
            parameters_json: "[]" }
    assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "F", symbol: sym)
    end
  end

  def test_inference_closed_loop_passes_failure_detail_to_second_attempt
    seeds_received = []
    backend = Object.new
    backend.define_singleton_method(:name) { "claude_p" }
    call_count = 0
    backend.define_singleton_method(:generate_glue) do |**kw|
      seeds_received << kw[:seed]
      call_count += 1
      call_count == 1 ? nil : AppleSDKMac::Inference::BackendResult.new(swift_source: "@c public func glue_x_Sym() {}")
    end

    fake_template = Object.new
    fake_template.define_singleton_method(:generate) { |**| nil }

    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**| }

    gates = Object.new
    gates.define_singleton_method(:validate) { |*, **| Struct.new(:pass?, :errors).new(true, []) }

    swiftc = Object.new
    swiftc.define_singleton_method(:compile) { |dylib_path:, **| File.write(dylib_path, ""); [true, nil] }

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/dev/null",
      template_generator: fake_template, gates: gates,
      swiftc_invoker: swiftc, inference_backend: backend,
      inference_budget: 3
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()", parameters_json: "[]" }
    result = compiler.compile(framework: "F", symbol: sym)
    assert_true result.success?
    assert_equal 2, call_count, "should call backend twice (first nil, second valid)"
    assert_not_nil seeds_received[1], "second call should receive a seed hash"
    assert_not_nil seeds_received[1][:failure_detail], "second seed should carry failure_detail from first attempt"
  end

  def test_inference_loud_fail_on_budget_exhaustion
    backend = Object.new
    backend.define_singleton_method(:name) { "claude_p" }
    backend.define_singleton_method(:generate_glue) { |**| nil }

    fake_template = Object.new
    fake_template.define_singleton_method(:generate) { |**| nil }

    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/dev/null",
      template_generator: fake_template, inference_backend: backend,
      inference_budget: 2
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()", parameters_json: "[]" }
    err = assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "F", symbol: sym)
    end
    assert_match(/exhausted budget=2/, err.reason)
  end

  def test_retry_with_resumes_inference_with_user_context_and_succeeds
    seen_contexts = []
    backend = Object.new
    backend.define_singleton_method(:name) { "claude_p" }
    backend.define_singleton_method(:generate_glue) do |**kw|
      ctx = kw[:seed][:context]
      seen_contexts << ctx
      ctx ? AppleSDKMac::Inference::BackendResult.new(swift_source: "@c public func glue_x_Sym() {}") : nil
    end

    fake_template = Object.new
    fake_template.define_singleton_method(:generate) { |**| nil }

    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**| }

    gates = Object.new
    gates.define_singleton_method(:validate) { |*, **| Struct.new(:pass?, :errors).new(true, []) }

    swiftc = Object.new
    swiftc.define_singleton_method(:compile) { |dylib_path:, **| File.write(dylib_path, ""); [true, nil] }

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/dev/null",
      template_generator: fake_template, gates: gates,
      swiftc_invoker: swiftc, inference_backend: backend,
      inference_budget: 1
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()", parameters_json: "[]" }

    err = assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "F", symbol: sym)
    end
    assert_nil seen_contexts.last, "first run should see no user context"
    assert_not_nil err.last_failure_detail, "error should carry the last failure detail"

    result = err.retry_with(context: "Use UInt32 return type")
    assert_true result.success?, "retry with user context should succeed"
    assert_equal "inference:claude_p", result.generator
    assert_equal "Use UInt32 return type", seen_contexts.last,
      "user context must reach the backend seed on retry"
  end

  def with_stub(mod, name, value)
    original = mod.method(name)
    mod.define_singleton_method(name) { |*_args, **_kw| value }
    yield
  ensure
    mod.singleton_class.send(:remove_method, name)
    mod.define_singleton_method(name, original)
  end

  def test_irb_elicitation_invoked_on_budget_exhaustion_in_irb_session
    backend = Object.new
    backend.define_singleton_method(:name) { "claude_p" }
    contexts_received = []
    backend.define_singleton_method(:generate_glue) do |**kw|
      contexts_received << kw.dig(:seed, :context)
      kw.dig(:seed, :context) ? AppleSDKMac::Inference::BackendResult.new(swift_source: "@c public func glue_x_Sym() {}") : nil
    end

    fake_template = Object.new
    fake_template.define_singleton_method(:generate) { |**| nil }

    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**| }

    gates = Object.new
    gates.define_singleton_method(:validate) { |*, **| Struct.new(:pass?, :errors).new(true, []) }
    swiftc = Object.new
    swiftc.define_singleton_method(:compile) { |dylib_path:, **| File.write(dylib_path, ""); [true, nil] }

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/dev/null",
      template_generator: fake_template, gates: gates,
      swiftc_invoker: swiftc, inference_backend: backend,
      inference_budget: 1
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()", parameters_json: "[]" }

    with_stub(AppleSDKMac::IrbElicitation, :available?, true) do
      with_stub(AppleSDKMac::IrbElicitation, :elicit, "Use UInt32 return") do
        result = compiler.compile(framework: "F", symbol: sym)
        assert_true result.success?
        assert_includes contexts_received, "Use UInt32 return"
      end
    end
  end
end

class GlueCompilerRoundTripIntegrationTest < Test::Unit::TestCase
  BR = AppleSDKMac::Inference::BackendResult
  RTOutcome = Struct.new(:green?, :detail, keyword_init: true)

  def setup
    @project_dir = Dir.mktmpdir
    @glue_store = AppleSDKMac::GlueStore.new(project_dir: @project_dir, sdk_version: "26.5")
  end

  def teardown
    FileUtils.remove_entry(@project_dir) if @project_dir && File.exist?(@project_dir)
  end

  def make_cache
    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**| }
    cache
  end

  def passthrough_gates
    g = Object.new
    g.define_singleton_method(:validate) { |*, **| Struct.new(:pass?, :errors).new(true, []) }
    g
  end

  def ok_swiftc
    s = Object.new
    s.define_singleton_method(:compile) { |dylib_path:, **| File.write(dylib_path, ""); [true, nil] }
    s
  end

  def nil_template
    t = Object.new
    t.define_singleton_method(:generate) { |**| nil }
    t
  end

  def backend_returning(result)
    b = Object.new
    b.define_singleton_method(:name) { "claude_p" }
    b.define_singleton_method(:generate_glue) { |**| result }
    b
  end

  UNCOVERED_SYM = { name: "Sym", kind: "swift_macro", abi: "swift",
                    signature: "()", parameters_json: "[]" }.freeze

  def test_round_trip_green_persists_test_and_outcome
    backend = backend_returning(BR.new(
      swift_source: "@c public func glue_x_Sym() -> UInt32 { 0 }",
      driver_inputs: { call_expr: "Foo()", invoke_args: [], value_kind: :value }
    ))
    runner = Object.new
    runner.define_singleton_method(:run) { |**| RTOutcome.new(green?: true, detail: "equivalent") }

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: make_cache, runtime_dylib_path: "/dev/null",
      template_generator: nil_template, gates: passthrough_gates,
      swiftc_invoker: ok_swiftc, inference_backend: backend,
      glue_store: @glue_store, round_trip_runner: runner
    )
    result = compiler.compile(framework: "F", symbol: UNCOVERED_SYM)
    assert_true result.success?, result.error_detail

    prov = @glue_store.provenance_entries.first
    assert_not_nil prov, "provenance sidecar must be written"
    assert_match(/\Agreen:/, prov["round_trip_outcome"])
    rtt_path = @glue_store.round_trip_test_path(framework: "F", symbol_name: "Sym")
    assert File.exist?(rtt_path), "round_trip_test must be persisted"
    assert_false File.read(rtt_path).empty?
  end

  def test_round_trip_red_fails_attempt_and_loud_fails_on_budget
    backend = backend_returning(BR.new(
      swift_source: "@c public func glue_x_Sym() -> UInt32 { 0 }",
      driver_inputs: { call_expr: "Foo()", invoke_args: [], value_kind: :value }
    ))
    runner = Object.new
    runner.define_singleton_method(:run) { |**| RTOutcome.new(green?: false, detail: "mismatch: swift=1 ruby=2") }

    err = nil
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: make_cache, runtime_dylib_path: "/dev/null",
      template_generator: nil_template, gates: passthrough_gates,
      swiftc_invoker: ok_swiftc, inference_backend: backend,
      glue_store: @glue_store, round_trip_runner: runner, inference_budget: 2
    )
    err = assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "F", symbol: UNCOVERED_SYM)
    end
    assert_match(/round-trip RED/, err.last_failure_detail)
    assert_equal [], @glue_store.provenance_entries, "RED glue must not be persisted as success"
  end

  def test_no_driver_inputs_skips_round_trip_and_succeeds
    backend = backend_returning(BR.new(
      swift_source: "@c public func glue_x_Sym() {}", driver_inputs: nil
    ))
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: make_cache, runtime_dylib_path: "/dev/null",
      template_generator: nil_template, gates: passthrough_gates,
      swiftc_invoker: ok_swiftc, inference_backend: backend,
      glue_store: @glue_store
    )
    result = compiler.compile(framework: "F", symbol: UNCOVERED_SYM)
    assert_true result.success?
    rtt_path = @glue_store.round_trip_test_path(framework: "F", symbol_name: "Sym")
    assert_false File.exist?(rtt_path), "no round_trip_test when round-trip skipped"
  end

  def test_c_fallback_synthesizes_driver_inputs_when_backend_omits
    backend = backend_returning(BR.new(
      swift_source: "@c public func glue_x_Sym() -> Int32 {\n  return NativeCall(1)\n}",
      driver_inputs: nil
    ))
    seen = nil
    runner = Object.new
    runner.define_singleton_method(:run) { |**kw| seen = kw[:symbol]; RTOutcome.new(green?: true, detail: "equivalent") }
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: make_cache, runtime_dylib_path: "/dev/null",
      template_generator: nil_template, gates: passthrough_gates,
      swiftc_invoker: ok_swiftc, inference_backend: backend,
      glue_store: @glue_store, round_trip_runner: runner
    )
    result = compiler.compile(framework: "F", symbol: UNCOVERED_SYM)
    assert_true result.success?
    assert_equal "NativeCall(1)", seen[:call_expr], "C fallback call_expr must reach the runner"
  end
end

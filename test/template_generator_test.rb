# frozen_string_literal: true
require "test_helper"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGenerator < Test::Unit::TestCase
  def setup
    @gen = AppleSDKMac::GlueCompiler::TemplateGenerator.new
  end

  def test_recognizes_pure_c_function_with_string_args
    sym = {
      name: "MIDIClientCreate",
      kind: "function",
      abi: "c",
      signature: "OSStatus MIDIClientCreate(CFStringRef name, MIDIClientRef *outRef)",
      parameters_json: JSON.dump([
        { "name" => "name", "type" => "CFStringRef",
          "kind" => "string", "is_out_param" => false, "nullability" => "unspecified" },
        { "name" => "outRef", "type" => "MIDIClientRef *",
          "kind" => "opaque_ref", "is_out_param" => true, "nullability" => "unspecified" }
      ])
    }
    swift = @gen.generate(framework: "CoreMIDI", symbol: sym, glue_id: "abc")
    refute_nil swift
    assert_match(/import CoreMIDI/, swift)
    assert_match(/glue_abc_MIDIClientCreate/, swift)
  end

  def test_returns_nil_for_unknown_shape
    sym = {
      name: "WeirdGenericFn",
      kind: "function",
      abi: "swift",
      signature: "func WeirdGenericFn<T: Equatable, U: Hashable>(...) async throws -> AsyncStream<T>"
    }
    swift = @gen.generate(framework: "Foo", symbol: sym, glue_id: "x")
    assert_nil swift
  end

  # Task 9 characterization: every existing kind dispatches and produces
  # non-nil Swift containing the kind's signature marshalling expression.
  # This pins behavior before the Marshaller refactor.
  def test_marshaller_dispatch_byte_identical_for_existing_kinds
    fixtures = [
      { kind: "string",     params: '[{"name":"s","type":"const char *","kind":"string","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(const char *)",
        expect: /String\(cString: rb_string_value_cstr/ },
      { kind: "int",        params: '[{"name":"n","type":"int","kind":"int","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(int)",
        expect: /let n: Int64 = rb_num2ll/ },
      { kind: "bool",       params: '[{"name":"b","type":"BOOL","kind":"bool","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(BOOL)",
        expect: /let b: Bool = / },
      { kind: "float",      params: '[{"name":"f","type":"double","kind":"float","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(double)",
        expect: /let f: Double = rb_num2dbl/ },
      { kind: "opaque_ref", params: '[{"name":"r","type":"MIDIClientRef","kind":"opaque_ref","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(MIDIClientRef)",
        expect: /MIDIClientRef\(rb_num2ull/ }
    ]
    fixtures.each do |fx|
      sym = { kind: "function", abi: "c", name: "Foo", signature: fx[:sig],
              parameters_json: fx[:params] }
      swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
      refute_nil swift, "kind=#{fx[:kind]} should generate Swift"
      assert_match fx[:expect], swift,
        "kind=#{fx[:kind]} expected pattern #{fx[:expect]}"
    end
  end
end

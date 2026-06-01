# frozen_string_literal: true
require "test_helper"

# DiscoveryShape — symbol-record domain transformations used by
# Apple.discover. Public surface is the synthesize_symbol_record + the
# override_c_symbol_params + the KIND_SYM_TO_TYPE constant. Stateless
# module form. Extracted from public_api.rb so the public API file can
# focus on orchestration (transient-tier register, compile, install) and
# the synthesis case-dispatch lives next to its data.
class TestDiscoveryShape < Test::Unit::TestCase
  def test_kind_sym_to_type_constant_present
    map = AppleSDKMac::DiscoveryShape::KIND_SYM_TO_TYPE
    assert_equal "const char *", map[:string]
    assert_equal "Int64",        map[:int]
    assert_equal "Bool",         map[:bool]
    assert_equal "Double",       map[:float]
    assert_equal "OpaquePointer", map[:opaque_ref]
    assert_equal "CFTypeRef",    map[:cftype_ref]
  end

  def test_synthesize_c_symbol_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :CoreMIDI, symbol: :MIDIClientCreate
    )
    assert_equal "MIDIClientCreate", rec[:name]
    assert_equal "function", rec[:kind]
    assert_equal "c", rec[:abi]
  end

  def test_synthesize_objc_class_method_canonical_name_strips_trailing_colon
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Foundation, klass: :NSString,
      class_method: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref
    )
    assert_equal "objc_method_class", rec[:kind]
    assert_equal "NSString.stringWithUTF8String", rec[:name]
    assert_equal "NSString", rec[:objc_class]
  end

  def test_synthesize_objc_instance_init_multi_segment_swift_form
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Vision, klass: :VNImageRequestHandler,
      selector: "initWithCGImage:options:",
      params: [:cftype_ref, :void_ptr_nilable], return_kind: :opaque_ref
    )
    assert_equal "objc_method_instance", rec[:kind]
    assert_equal "VNImageRequestHandler.init(cgImage:options:)", rec[:name]
  end

  def test_synthesize_swift_initializer_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Foundation, klass: :URL,
      swift_initializer: "init(string:)",
      params: [:string], return_kind: :opaque_ref
    )
    assert_equal "swift_init", rec[:kind]
    assert_equal "URL.init(string:)", rec[:name]
    assert_equal "URL", rec[:swift_class]
  end

  def test_synthesize_swift_property_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Foundation, klass: :ProcessInfo,
      swift_property: :processIdentifier, return_kind: :int
    )
    assert_equal "swift_property", rec[:kind]
    assert_equal "ProcessInfo.processIdentifier", rec[:name]
  end

  # swift_property + setter: true → kind="swift_property_setter"。 public
  # Apple.discover から setter kind を踏める唯一の経路。 emit_swift_property_setter
  # は params (>=1, value 型) を必須にするため synthesize が return_kind を
  # value 型として params に積み、 name に "=" suffix を付ける (Ruby setter 命名)。
  def test_synthesize_swift_property_setter_record_when_setter_true
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :AVFoundation, klass: :AVSpeechUtterance,
      swift_property: :rate, instance: true, return_kind: :float, setter: true
    )
    assert_equal "swift_property_setter", rec[:kind]
    assert_equal "AVSpeechUtterance.rate=", rec[:name]
    assert_equal "AVSpeechUtterance", rec[:swift_class]
    assert_equal "rate", rec[:swift_property]
    assert_equal [:float], rec[:params],
      "setter は value 型を params[0] に持つ (emit_swift_property_setter の必須前提)"
    assert_equal true, rec[:instance]
  end

  # setter: なしは従来どおり getter kind="swift_property"。 setter flag が
  # getter path を汚染しないことの回帰確認。
  def test_synthesize_swift_property_without_setter_stays_getter
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :AVFoundation, klass: :AVSpeechUtterance,
      swift_property: :speechString, instance: true, return_kind: :string
    )
    assert_equal "swift_property", rec[:kind]
    assert_equal "AVSpeechUtterance.speechString", rec[:name]
  end

  # constant: → kind="global_constant" / abi="c"。 emit_global_constant の
  # global_constant_value_kind が numeric token を拾えるよう、 return_kind から
  # numeric な signature を合成する (:float → double)。
  def test_synthesize_global_constant_float_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :CoreFoundation, constant: :kCFCoreFoundationVersionNumber,
      return_kind: :float
    )
    assert_equal "global_constant", rec[:kind]
    assert_equal "c", rec[:abi]
    assert_equal "kCFCoreFoundationVersionNumber", rec[:name]
    assert_match(/\bdouble\b/, rec[:signature].to_s,
      "global_constant_value_kind が :float を拾える numeric signature を合成する")
  end

  # constant: + return_kind :int → integer 系の signature token。
  def test_synthesize_global_constant_integer_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Foundation, constant: :NSIntegerMaxConst, return_kind: :int
    )
    assert_equal "global_constant", rec[:kind]
    assert_match(/\bNSInteger\b/, rec[:signature].to_s)
  end

  def test_synthesize_swift_func_record
    rec = AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
      framework: :Foundation, swift_func: :decode,
      type_args: [:User], params: [:string], return_kind: :opaque_ref
    )
    assert_equal "swift_func", rec[:kind]
    assert_equal [:User], rec[:type_args]
  end

  def test_synthesize_unknown_keyword_raises_discovery_error
    assert_raises(AppleSDKMac::DiscoveryError) do
      AppleSDKMac::DiscoveryShape.synthesize_symbol_record(
        framework: :Foundation, junk: 1
      )
    end
  end

  def test_override_c_symbol_params_rewrites_parameters_json_from_symbol_array
    base = { id: 1, name: "TestSym", kind: "function", abi: "c",
             parameters_json: "[]", signature: nil, documentation: nil,
             requires_main_thread: false, content_hash: nil, fields_json: nil }
    overridden = AppleSDKMac::DiscoveryShape.override_c_symbol_params(
      base, params: [:string, :int]
    )
    parsed = JSON.parse(overridden[:parameters_json], symbolize_names: true)
    assert_equal 2, parsed.length
    assert_equal "const char *", parsed[0][:type]
    assert_equal "string", parsed[0][:kind]
    assert_equal "Int64", parsed[1][:type]
  end

  def test_override_c_symbol_params_accepts_hash_form_with_type_hint
    base = { id: 1, name: "TestSym", kind: "function", abi: "c",
             parameters_json: "[]", signature: nil, documentation: nil,
             requires_main_thread: false, content_hash: nil, fields_json: nil }
    overridden = AppleSDKMac::DiscoveryShape.override_c_symbol_params(
      base,
      params: [{ kind: :opaque_ref, type: "CFURLRef", nilable: false }]
    )
    parsed = JSON.parse(overridden[:parameters_json], symbolize_names: true)
    assert_equal "CFURLRef", parsed[0][:type]
    assert_equal "opaque_ref", parsed[0][:kind]
    assert_equal false, parsed[0][:nilable]
  end

  def test_override_c_symbol_params_embeds_return_kind_when_present
    base = { id: 1, name: "TestSym", kind: "function", abi: "c",
             parameters_json: "[]", signature: nil, documentation: nil,
             requires_main_thread: false, content_hash: nil, fields_json: nil }
    overridden = AppleSDKMac::DiscoveryShape.override_c_symbol_params(
      base, return_kind: :int
    )
    assert_equal :int, overridden[:return_kind]
  end
end

# frozen_string_literal: true
require "test_helper"

# Phase 7 T5 — Apple.discover polymorphic single entry. spec §3.2.
#
# Apple.discover accepts 7 keyword shapes and synthesizes a symbol record
# with the correct `kind` for each. Each shape is registered into the
# KnowledgeCache transient lookup tier so the existing compile pipeline
# picks the right glue path (TemplateGenerator for kind=function/abi=c,
# LLMGenerator for everything else).
#
# These tests pin the synthesis + registration contract. End-to-end
# compile + dispatch is exercised by integration tests / examples.
class TestPublicApiDiscoverPolymorphic < Test::Unit::TestCase
  def teardown
    cache = AppleSDKMac.knowledge_cache
    cache.respond_to?(:clear_transient!) && cache.clear_transient!
  end

  def test_synthesize_c_symbol_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :CoreMIDI, symbol: :MIDIClientCreate
    )
    assert_equal "MIDIClientCreate", rec[:name]
    assert_equal "function", rec[:kind]
    assert_equal "c",        rec[:abi]
  end

  def test_synthesize_objc_instance_method_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Vision, klass: :VNImageRequestHandler,
      selector: "initWithCGImage:options:",
      params: [:cftype_ref, :void_ptr_nilable],
      return_kind: :opaque_ref
    )
    assert_equal "objc_method_instance", rec[:kind]
    assert_equal "VNImageRequestHandler", rec[:objc_class]
    assert_equal "initWithCGImage:options:", rec[:selector]
    assert_equal [:cftype_ref, :void_ptr_nilable], rec[:params]
    assert_equal :opaque_ref, rec[:return_kind]
  end

  def test_synthesize_objc_class_method_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Foundation, klass: :NSString,
      class_method: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref
    )
    assert_equal "objc_method_class", rec[:kind]
    assert_equal "NSString", rec[:objc_class]
    assert_equal "stringWithUTF8String:", rec[:selector]
  end

  def test_synthesize_swift_func_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Foundation, swift_func: :runtime_async_test_sleep_and_double,
      params: [:int], return_kind: :int
    )
    assert_equal "swift_func", rec[:kind]
    assert_equal "runtime_async_test_sleep_and_double", rec[:swift_func]
  end

  def test_synthesize_swift_initializer_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Foundation, klass: :URL,
      swift_initializer: "init(string:)",
      params: [:string], return_kind: :opaque_ref
    )
    assert_equal "swift_init", rec[:kind]
    assert_equal "URL", rec[:swift_class]
    assert_equal "init(string:)", rec[:swift_initializer]
  end

  def test_synthesize_swift_property_record
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Foundation, klass: :ProcessInfo,
      swift_property: :processIdentifier, return_kind: :int
    )
    assert_equal "swift_property", rec[:kind]
    assert_equal "ProcessInfo", rec[:swift_class]
    assert_equal "processIdentifier", rec[:swift_property]
  end

  def test_synthesize_with_type_args
    rec = AppleSDKMac._synthesize_symbol_record(
      framework: :Foundation, swift_func: :decode,
      type_args: [:User], params: [:string], return_kind: :opaque_ref
    )
    assert_equal "swift_func", rec[:kind]
    assert_equal [:User], rec[:type_args]
  end

  def test_discover_with_no_recognized_keyword_raises_discovery_error
    assert_raises(Apple::DiscoveryError) do
      AppleSDKMac._synthesize_symbol_record(framework: :Foundation, junk: 1)
    end
  end

  # Transient lookup tier — register_transient + lookup_symbol round trip.
  def test_knowledge_cache_register_and_lookup_transient
    cache = AppleSDKMac.knowledge_cache
    record = {
      id: -1, name: "TestSym", kind: "objc_method_class", signature: nil,
      abi: nil, documentation: nil, parameters_json: "[]",
      requires_main_thread: false, content_hash: nil, fields_json: nil,
      objc_class: "NSString", selector: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref
    }
    cache.register_transient(framework: "Foundation", symbol: "TestSym", record: record)
    rec = cache.lookup_symbol(framework: "Foundation", symbol: "TestSym")
    assert_not_nil rec
    assert_equal "objc_method_class", rec[:kind]
    assert_equal "NSString", rec[:objc_class]
  end

  # Transient must overlay (not collide with) DB rows. If a symbol exists
  # in the DB, register_transient with the same name overrides it for the
  # lifetime of the cache instance — primarily for test isolation and for
  # users who want to override a discover result.
  def test_transient_overlays_db_records
    cache = AppleSDKMac.knowledge_cache
    db_rec = cache.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    skip "MIDIClientCreate not in KB; cannot test overlay" unless db_rec
    overlay = { id: -2, name: "MIDIClientCreate", kind: "stub_for_test",
                signature: nil, abi: nil, documentation: nil,
                parameters_json: "[]", requires_main_thread: false,
                content_hash: nil, fields_json: nil }
    cache.register_transient(framework: "CoreMIDI", symbol: "MIDIClientCreate", record: overlay)
    got = cache.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    assert_equal "stub_for_test", got[:kind],
      "register_transient must overlay DB rows for caller-controlled override"
  end
end

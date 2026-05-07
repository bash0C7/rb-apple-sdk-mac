# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/doc_resolver"

# DocResolver は popup hover 中の candidate string (full-prefix
# Apple::Framework[::Klass[.method]] 形) を受けて、 KnowledgeCache の
# lookup_documentation 経由で Apple SDK doc 文字列を返す。 Apple SDK 形式
# でない / 該当 doc が無い場合は nil。 sub-gem の :show_doc dialog から呼ばれる。
class TestDocResolver < Test::Unit::TestCase
  Resolver = AppleSDKMac::IRB::DocResolver

  def make_cache(records, framework_records = {})
    cache = Object.new
    cache.define_singleton_method(:lookup_documentation) do |framework:, name:, klass: nil|
      records[[framework, klass, name]]
    end
    cache.define_singleton_method(:lookup_framework_documentation) do |name:|
      framework_records[name]
    end
    cache
  end

  def test_resolves_class_method_via_kb
    cache = make_cache(
      ["Foundation", "URL", "appendingPathComponent"] => "Returns a new URL by appending the supplied path component."
    )
    out = Resolver.new(knowledge_cache: cache).resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "Returns a new URL by appending the supplied path component.", out
  end

  def test_resolves_top_level_type
    cache = make_cache(
      ["CoreFoundation", nil, "CFArrayAppendValue"] => "Adds the value to the array."
    )
    out = Resolver.new(knowledge_cache: cache).resolve("Apple::CoreFoundation::CFArrayAppendValue")
    assert_equal "Adds the value to the array.", out
  end

  def test_returns_nil_for_non_apple_input
    cache = make_cache({})
    assert_nil Resolver.new(knowledge_cache: cache).resolve("String.length")
  end

  def test_returns_framework_doc_for_apple_root
    cache = make_cache({}, { "ARKit" => "ARKit framework. 302 symbols indexed." })
    out = Resolver.new(knowledge_cache: cache).resolve("Apple::ARKit")
    assert_equal "ARKit framework. 302 symbols indexed.", out
  end

  def test_returns_nil_for_apple_root_when_unknown_framework
    cache = make_cache({}, {})
    assert_nil Resolver.new(knowledge_cache: cache).resolve("Apple::ZzNoSuchFw")
  end

  def test_returns_nil_when_kb_has_no_doc
    cache = make_cache({}) # always nil
    assert_nil Resolver.new(knowledge_cache: cache).resolve("Apple::Foundation::URL.appendingPathComponent")
  end

  # doc_transform hook (Step 6.1) — used by install! to inject a
  # translator that runs the raw KB doc through Apple Intelligence
  # when LANG ≠ en. The hook is the only point sub-gem code touches
  # for doc post-processing; the actual translator gem stays optional.

  def test_doc_transform_default_is_identity
    cache = make_cache(
      ["Foundation", "URL", "appendingPathComponent"] => "raw doc"
    )
    out = Resolver.new(knowledge_cache: cache).resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "raw doc", out
  end

  def test_doc_transform_replaces_resolved_doc
    cache = make_cache(
      ["Foundation", "URL", "appendingPathComponent"] => "raw doc"
    )
    transform = ->(doc, _ctx) { "translated: #{doc}" }
    out = Resolver.new(knowledge_cache: cache, doc_transform: transform)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "translated: raw doc", out
  end

  def test_doc_transform_receives_parsed_context
    cache = make_cache(
      ["Foundation", "URL", "appendingPathComponent"] => "raw"
    )
    seen_ctx = nil
    transform = ->(doc, ctx) { seen_ctx = ctx; doc }
    Resolver.new(knowledge_cache: cache, doc_transform: transform)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "Foundation", seen_ctx.framework
    assert_equal "URL", seen_ctx.klass
    assert_equal :class, seen_ctx.receiver_kind
  end

  def test_doc_transform_not_called_when_lookup_misses
    cache = make_cache({})
    called = false
    transform = ->(_doc, _ctx) { called = true; "should not appear" }
    out = Resolver.new(knowledge_cache: cache, doc_transform: transform)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_nil out
    refute called
  end

  def test_doc_transform_can_suppress_via_nil
    cache = make_cache(
      ["Foundation", "URL", "appendingPathComponent"] => "raw"
    )
    transform = ->(_doc, _ctx) { nil }
    out = Resolver.new(knowledge_cache: cache, doc_transform: transform)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_nil out
  end
end

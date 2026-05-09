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
end

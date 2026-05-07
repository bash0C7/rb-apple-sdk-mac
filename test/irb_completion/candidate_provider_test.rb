# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionCandidateProvider < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context
  CandidateProvider = AppleSDKMac::IRBCompletion::CandidateProvider

  class FakeKnowledgeCache
    def initialize(frameworks: [], symbols: {}, klass_methods: {})
      @frameworks = frameworks
      @symbols = symbols
      @klass_methods = klass_methods
    end

    def list_frameworks
      @frameworks
    end

    def list_framework_symbols(framework:, kinds: nil)
      rows = @symbols[framework] || []
      rows = rows.select { |r| Array(kinds).include?(r[:kind]) } if kinds
      rows
    end

    def list_klass_methods(framework:, klass:)
      @klass_methods[[framework, klass]] || []
    end
  end

  def test_apple_root_lists_frameworks_uppercase_only
    cache = FakeKnowledgeCache.new(frameworks: ["Foundation", "Vision", "_Internal"])
    ctx = Context.parse("Apple::")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["Foundation", "Vision"], out.sort
  end

  def test_apple_root_with_prefix_filters
    cache = FakeKnowledgeCache.new(frameworks: ["Foundation", "FileProvider", "Vision"])
    ctx = Context.parse("Apple::F")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["FileProvider", "Foundation"], out.sort
  end

  def test_module_lists_class_kind_constants_with_prefix
    cache = FakeKnowledgeCache.new(symbols: {
      "Foundation" => [
        {name: "NSData", kind: "class"},
        {name: "NSString", kind: "class"},
        {name: "NSCalendar", kind: "class"},
        {name: "kCFAllocatorDefault", kind: "global_constant"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NS")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["NSCalendar", "NSData", "NSString"], out.sort
  end

  def test_class_lists_methods_via_list_klass_methods
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "class_method"},
        {name: "length", kind: "instance_method"},
        {name: "bytes", kind: "instance_method"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NSData.")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_includes out, "dataWithContentsOfFile"
    assert_includes out, "length"
    assert_includes out, "bytes"
  end

  def test_class_with_prefix_filters_methods
    cache = FakeKnowledgeCache.new(klass_methods: {
      ["Foundation", "NSData"] => [
        {name: "dataWithContentsOfFile:", kind: "class_method"},
        {name: "dataWithContentsOfURL:", kind: "class_method"},
        {name: "length", kind: "instance_method"}
      ]
    })
    ctx = Context.parse("Apple::Foundation::NSData.dataW")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal ["dataWithContentsOfFile", "dataWithContentsOfURL"], out.sort
  end

  def test_caps_at_100
    rows = (1..150).map { |i| {name: "method#{i}", kind: "instance_method"} }
    cache = FakeKnowledgeCache.new(klass_methods: {["Foundation", "NSData"] => rows})
    ctx = Context.parse("Apple::Foundation::NSData.")
    out = CandidateProvider.new(knowledge_cache: cache).call(ctx)
    assert_equal 100, out.size
  end
end

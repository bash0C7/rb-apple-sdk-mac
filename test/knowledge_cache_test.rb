# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/knowledge_cache"

class TestKnowledgeCache < Test::Unit::TestCase
  def test_lookup_symbol_returns_nil_for_unknown
    omit "knowledge SQLite not built; run rake apple:knowledge:rebuild" unless real_knowledge_built?
    cache = AppleSDKMac::KnowledgeCache.open
    assert_nil cache.lookup_symbol(framework: "CoreMIDI", symbol: "DefinitelyNotARealAPI___xyz")
    cache.close
  end

  def test_lookup_real_known_symbol
    omit "knowledge SQLite not built" unless real_knowledge_built?
    cache = AppleSDKMac::KnowledgeCache.open
    sym = cache.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    assert_not_nil sym
    assert_equal "function", sym[:kind]
    cache.close
  end

  private

  def real_knowledge_built?
    require "rb_apple_sdk_knowledge"
    File.exist?(AppleSDKKnowledge.knowledge_path)
  rescue
    false
  end
end

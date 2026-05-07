# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
require "apple_sdk_mac/knowledge_cache"
require "rb_apple_sdk_knowledge/store"

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

  # Task 8: KnowledgeCache#lookup_symbol surfaces fields_json. Self-contained
  # unit test using an in-memory store fixture (no dependency on rebuilt DB).
  def test_lookup_symbol_surfaces_fields_json
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      fid = store.insert_framework(name: "Acme", swift_module: "Acme")
      fields = JSON.dump([
        { name: "x", type: "Int32", kind: "int" },
        { name: "y", type: "Int32", kind: "int" }
      ])
      store.insert_symbol(framework_id: fid, name: "Pt", kind: "struct", abi: "c",
                          content_hash: "h-pt", fields_json: fields)

      cache = AppleSDKMac::KnowledgeCache.new(store)
      sym = cache.lookup_symbol(framework: "Acme", symbol: "Pt")
      assert_not_nil sym
      assert_equal "struct", sym[:kind]
      assert_equal fields, sym[:fields_json]
      cache.close
    end
  end

  def test_list_klass_methods_returns_methods_with_parent_class
    cache = AppleSDKMac.knowledge_cache
    # Foundation.URL (Swift struct) は appendingPathComponent 等の instance_method
    # を多数持つ。 KB importer が parent_id を populate していない場合 0 で fail。
    # NSString は ObjC native で swiftinterface 経由の KB には出てこない。
    rows = cache.list_klass_methods(framework: "Foundation", klass: "URL")
    assert_operator rows.size, :>=, 1, "Foundation.URL must have at least 1 child method"
    rows.each do |r|
      assert r.key?(:name)
      assert r.key?(:kind)
    end
  end

  def test_list_klass_methods_unknown_klass_empty
    cache = AppleSDKMac.knowledge_cache
    rows = cache.list_klass_methods(framework: "Foundation", klass: "ClassThatDoesNotExist__")
    assert_equal [], rows
  end

  private

  def real_knowledge_built?
    require "rb_apple_sdk_knowledge"
    File.exist?(AppleSDKKnowledge.knowledge_path)
  rescue
    false
  end
end

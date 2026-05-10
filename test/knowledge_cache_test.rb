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

  # Phase F follow-up (2026-05-08) — KB symbols は parent_id 階層で索引されて
  # おり、 "URL.appendingPathComponent" のような flat name は lookup_symbol で
  # 必ず miss する。 lookup_klass_method は klass + method を分けて parent_id
  # JOIN で正確に hit させる。
  def test_lookup_klass_method_returns_record_for_known
    cache = AppleSDKMac.knowledge_cache
    rec = cache.lookup_klass_method(framework: "Foundation", klass: "URL",
                                    method: "appendingPathComponent")
    assert_not_nil rec, "Foundation::URL::appendingPathComponent must be indexed under URL.parent_id"
    assert_equal "appendingPathComponent", rec[:name]
    assert_match(/method/, rec[:kind])
  end

  def test_lookup_klass_method_returns_nil_for_unknown_method
    cache = AppleSDKMac.knowledge_cache
    assert_nil cache.lookup_klass_method(framework: "Foundation", klass: "URL",
                                          method: "noSuchMethod___xyz")
  end

  def test_lookup_klass_method_returns_nil_for_unknown_klass
    cache = AppleSDKMac.knowledge_cache
    assert_nil cache.lookup_klass_method(framework: "Foundation",
                                          klass: "ClassThatDoesNotExist__",
                                          method: "anything")
  end

  # Step 3.2 — KnowledgeCache.lookup_documentation for the irb sub-gem
  # :show_doc dialog. The 2026-05-08 KB rebuild populates symbols.documentation
  # for ObjC/C frameworks via clang's FullComment AST; CoreFoundation symbols
  # in particular carry rich docstrings.
  def test_lookup_documentation_returns_apple_doc_for_top_level_function
    cache = AppleSDKMac.knowledge_cache
    doc = cache.lookup_documentation(framework: "CoreFoundation", name: "CFArrayAppendValue")
    assert doc.is_a?(String) && !doc.empty?,
      "CFArrayAppendValue should carry a populated documentation field"
    assert_match(/Adds the value to the array/i, doc)
  end

  def test_lookup_documentation_returns_nil_for_unknown_symbol
    cache = AppleSDKMac.knowledge_cache
    doc = cache.lookup_documentation(framework: "CoreFoundation", name: "NoSuchSymbol__")
    assert_nil doc
  end

  def test_lookup_documentation_returns_nil_for_unknown_framework
    cache = AppleSDKMac.knowledge_cache
    doc = cache.lookup_documentation(framework: "NoSuchFramework__", name: "anything")
    assert_nil doc
  end

  def test_lookup_documentation_returns_nil_for_undocumented_swift_overlay
    cache = AppleSDKMac.knowledge_cache
    # Foundation::URL.appendingPathComponent comes from the Swift overlay,
    # whose *.swiftinterface is stripped of doc-comments by the compiler.
    # The lookup should return nil rather than an empty string.
    doc = cache.lookup_documentation(framework: "Foundation", klass: "URL", name: "appendingPathComponent")
    assert_nil doc
  end

  def test_lookup_framework_documentation_returns_synthesized_doc
    cache = AppleSDKMac.knowledge_cache
    doc = cache.lookup_framework_documentation(name: "ARKit")
    assert doc.is_a?(String) && !doc.empty?,
      "ARKit framework lookup must return a synthesized description even when frameworks.doc_url is empty"
    assert_match(/ARKit/i, doc)
    # Internal "N symbols indexed" gem metadata must not leak into user-facing doc dialog.
    refute_match(/symbol/i, doc)
    refute_match(/index/i, doc)
  end

  def test_lookup_framework_documentation_returns_nil_for_unknown
    cache = AppleSDKMac.knowledge_cache
    assert_nil cache.lookup_framework_documentation(name: "NoSuchFramework__")
  end

  private

  def real_knowledge_built?
    require "rb_apple_sdk_knowledge"
    File.exist?(AppleSDKKnowledge.knowledge_path)
  rescue
    false
  end
end

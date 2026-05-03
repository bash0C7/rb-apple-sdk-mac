# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/consolidator"
require "digest"

class TestConsolidator < Test::Unit::TestCase
  def test_merges_swift_interface_with_docc_documentation
    swift_syms = [
      { name: "MIDIClientCreate", kind: "function", abi: "swift",
        parent_name: nil, signature: "func MIDIClientCreate(...)" }
    ]
    docc_syms = [
      { name: "MIDIClientCreate", documentation: "Creates a new client.", kind_hint: "func" }
    ]
    c = AppleSDKKnowledge::Importer::Consolidator.new
    merged = c.merge(swift_syms, [], docc_syms)
    found = merged.find { |s| s[:name] == "MIDIClientCreate" }
    assert_not_nil found
    assert_equal "Creates a new client.", found[:documentation]
  end

  def test_assigns_content_hash
    swift_syms = [{ name: "F", kind: "function", abi: "swift", parent_name: nil, signature: "sig" }]
    c = AppleSDKKnowledge::Importer::Consolidator.new
    merged = c.merge(swift_syms, [], [])
    assert merged.first[:content_hash].is_a?(String)
    assert_equal 64, merged.first[:content_hash].length
  end

  def test_dedupes_when_swift_and_c_have_same_name_signature
    swift = [{ name: "F", kind: "function", abi: "swift", parent_name: nil, signature: "F() -> Int" }]
    c_syms = [{ name: "F", kind: "function", abi: "c", parent_name: nil, signature: "F() -> Int" }]
    cons = AppleSDKKnowledge::Importer::Consolidator.new
    merged = cons.merge(swift, c_syms, [])
    assert_equal 1, merged.count { |s| s[:name] == "F" }
  end

  def test_does_not_dedupe_methods_with_different_parents
    swift_syms = [
      { name: "init", kind: "class_method", abi: "swift",
        parent_name: "ClassA", signature: "init(_ x: Swift.Int)" },
      { name: "init", kind: "class_method", abi: "swift",
        parent_name: "ClassB", signature: "init(_ x: Swift.Int)" }
    ]
    cons = AppleSDKKnowledge::Importer::Consolidator.new
    merged = cons.merge(swift_syms, [], [])
    assert_equal 2, merged.count { |s| s[:name] == "init" },
      "expected init on ClassA and ClassB to be kept separately"
  end
end

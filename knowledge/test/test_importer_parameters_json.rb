# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer"

class TestImporterParametersJson < Test::Unit::TestCase
  class SpyStore
    attr_reader :inserted
    def initialize; @inserted = []; end
    def find_framework_id_by_name(_); nil; end
    def insert_framework(**); 1; end
    def insert_symbol(**kwargs); @inserted << kwargs; @inserted.length; end
    def vec_insert(*); end
  end

  def test_pipes_parameters_json_into_store
    Dir.mktmpdir do |tmp|
      pipeline = AppleSDKKnowledge::Importer::Pipeline.new(store_path: File.join(tmp, "kb.sqlite"))
      spy = SpyStore.new
      merged = [{
        name: "F", kind: "function", abi: "c", parent_name: nil,
        signature: "void F(int x)",
        parameters: [{ name: "x", type: "int" }]
      }]
      pipeline.send(:two_pass_insert, merged, spy, 1)

      sym = spy.inserted.first
      assert_not_nil sym, "expected exactly one insert_symbol call"
      assert_not_nil sym[:parameters_json],
                     "expected parameters_json to be passed through to store.insert_symbol"
      assert_equal '[{"name":"x","type":"int"}]', sym[:parameters_json]
    end
  end

  def test_pipes_fields_json_into_store_for_struct
    Dir.mktmpdir do |tmp|
      pipeline = AppleSDKKnowledge::Importer::Pipeline.new(store_path: File.join(tmp, "kb.sqlite"))
      spy = SpyStore.new
      merged = [{
        name: "Pt", kind: "struct", abi: "c", parent_name: nil,
        signature: "struct Pt",
        fields: [
          { name: "x", type: "int", kind: "int" },
          { name: "y", type: "int", kind: "int" }
        ]
      }]
      pipeline.send(:two_pass_insert, merged, spy, 1)

      sym = spy.inserted.first
      assert_not_nil sym, "expected exactly one insert_symbol call"
      assert_not_nil sym[:fields_json],
                     "expected fields_json to be passed through for struct symbols"
      parsed = JSON.parse(sym[:fields_json])
      assert_equal 2, parsed.length
      assert_equal "x", parsed[0]["name"]
    end
  end
end

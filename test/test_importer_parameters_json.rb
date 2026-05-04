# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
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

  FakeFramework = Struct.new(:name, :path)

  class FakeHeaderParser
    def parse_file(_)
      [{
        name: "F", kind: "function", abi: "c", parent_name: nil,
        signature: "void F(int x)",
        parameters: [{ name: "x", type: "int" }]
      }]
    end
  end

  class FakeSwiftParser
    def parse_file(_); []; end
  end

  def test_pipes_parameters_json_into_store
    Dir.mktmpdir do |tmp|
      headers_dir = File.join(tmp, "Headers")
      FileUtils.mkdir_p(headers_dir)
      File.write(File.join(headers_dir, "F.h"), "")

      pipeline = AppleSDKKnowledge::Importer::Pipeline.new(store_path: File.join(tmp, "kb.sqlite"))
      spy = SpyStore.new
      consolidator = AppleSDKKnowledge::Importer::Consolidator.new
      pipeline.send(:process_framework,
                    FakeFramework.new("X", tmp),
                    spy,
                    FakeSwiftParser.new,
                    FakeHeaderParser.new,
                    consolidator,
                    nil)

      sym = spy.inserted.first
      assert_not_nil sym, "expected exactly one insert_symbol call"
      assert_not_nil sym[:parameters_json],
                     "expected parameters_json to be passed through to store.insert_symbol"
      assert_equal '[{"name":"x","type":"int"}]', sym[:parameters_json]
    end
  end
end

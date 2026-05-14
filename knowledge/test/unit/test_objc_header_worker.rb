# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer/objc_header_worker"

class TestObjCHeaderWorker < Test::Unit::TestCase
  def test_returns_symbols_for_valid_header
    Dir.mktmpdir do |dir|
      header = File.join(dir, "Foo.h")
      File.write(header, "int foo_add(int a, int b);\n")
      worker = AppleSDKKnowledge::Importer::ObjCHeaderWorker.new(sdk_path: nil)
      result = worker.call(framework: "Foo", header: header)
      assert_nil result[:error]
      assert_kind_of Array, result[:result]
      names = result[:result].map { |s| s[:name] }
      assert_includes names, "foo_add"
      assert_operator result[:elapsed_ms], :>=, 0
    end
  end

  def test_returns_error_for_invalid_header
    Dir.mktmpdir do |dir|
      header = File.join(dir, "Broken.h")
      File.write(header, "this is not valid C\n")
      worker = AppleSDKKnowledge::Importer::ObjCHeaderWorker.new(sdk_path: nil)
      result = worker.call(framework: "Broken", header: header)
      assert_nil result[:result]
      assert_match(/clang failed/, result[:error])
    end
  end
end

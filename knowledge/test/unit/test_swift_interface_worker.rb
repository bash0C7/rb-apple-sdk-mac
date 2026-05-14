# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer/swift_interface_worker"

class TestSwiftInterfaceWorker < Test::Unit::TestCase
  def test_returns_symbols_for_valid_swiftinterface
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Foo.swiftinterface")
      File.write(path, <<~SWIFT)
        // swift-interface-format-version: 1.0
        // swift-module-flags: -module-name Foo
        public class FooBar {
          public init()
        }
      SWIFT
      worker = AppleSDKKnowledge::Importer::SwiftInterfaceWorker.new
      result = worker.call(framework: "Foo", path: path)
      assert_nil result[:error]
      assert_kind_of Array, result[:result]
      assert_operator result[:elapsed_ms], :>=, 0
    end
  end

  def test_returns_hash_structure_for_unparseable_input
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.swiftinterface")
      File.write(path, "garbage content")
      worker = AppleSDKKnowledge::Importer::SwiftInterfaceWorker.new
      result = worker.call(framework: "Bad", path: path)
      assert_kind_of Hash, result
      assert_includes [Array, NilClass], result[:result].class
    end
  end
end

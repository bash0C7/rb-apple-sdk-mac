# frozen_string_literal: true
require "test/unit"
require "apple_sdk_mac/glue_compiler/llm_generator"

class LLMGeneratorHeaderInjectionTest < Test::Unit::TestCase
  def test_injects_header_when_llm_response_lacks_silgen_name
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    bare_response = <<~SWIFT
      @c
      public func glue_dead_Foo(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
        return 0
      }
    SWIFT
    fixed = gen.send(:ensure_header, bare_response, framework: "AcmeFW")
    assert_includes fixed, "import AcmeFW"
    assert_includes fixed, "import Foundation"
    assert_includes fixed, '@_silgen_name("rb_num2ll")'
    # The actual @c function from LLM must remain
    assert_includes fixed, "glue_dead_Foo"
  end

  def test_passthrough_when_header_already_present
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    full_response = <<~SWIFT
      import AcmeFW
      import Foundation
      @_silgen_name("rb_num2ll")
      func rb_num2ll(_ v: UInt) -> Int64
      @c public func glue_dead_Foo(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { return 0 }
    SWIFT
    fixed = gen.send(:ensure_header, full_response, framework: "AcmeFW")
    # Should not double-inject
    assert_equal full_response.scan("import Foundation").count,
      fixed.scan("import Foundation").count
  end
end

# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/glue_compiler/validation_gates"

class TestValidationGates < Test::Unit::TestCase
  def setup
    @gates = AppleSDKMac::GlueCompiler::ValidationGates.new
  end

  def test_passes_minimal_correct_glue
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_MIDIDispose(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let h: UInt32 = UInt32(argv[0])
          let r = MIDIClientDispose(MIDIClientRef(h))
          return UInt(r)
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc",
                              symbol: "MIDIDispose")
    assert result.pass?, result.errors.join("; ")
  end

  def test_rejects_disallowed_import
    swift = <<~SWIFT
      import CoreMIDI
      import Network
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("Network") }
  end

  def test_rejects_url_session_call_in_body_for_unrelated_symbol
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_MIDIDispose(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          _ = URLSession.shared.dataTask(with: URL(string: "http://x")!)
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc",
                              symbol: "MIDIDispose")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("URLSession") }
  end

  def test_rejects_multiple_c_exports
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c public func glue_abc_a(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
      @c public func glue_abc_b(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc", symbol: "a")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("export") || e.include?("@c") }
  end
end

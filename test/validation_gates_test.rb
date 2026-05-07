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

  # T53e — BANNED API check は LLM が任意に持ち込む URLSession を弾くのが
  # 目的。 user が `Apple.discover(klass: :NSURLSession, ...)` で明示 discover
  # した場合、 target_symbol は `NSURLSession_<prop>` 形になる。 これは
  # 正当な discover なので URLSession 文字列 を含む glue を ban から除外する。
  # 既存の MIDIDispose 等 unrelated symbol で URLSession を持ち込む LLM 経路は
  # 引き続き ban される。
  def test_allows_url_session_when_symbol_targets_ns_url_session
    swift = <<~SWIFT
      import Foundation
      import AppleSDKMacRuntime

      @c
      public func glue_abc_NSURLSession_shared(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let raw = URLSession.shared
          let p = Unmanaged.passRetained(raw as AnyObject).toOpaque()
          return rb_ull2inum(UInt64(UInt(bitPattern: p)))
      }
    SWIFT
    result = @gates.validate(swift, framework: "Foundation", glue_id: "abc",
                              symbol: "NSURLSession_shared")
    # GATE 4 banned-API check は通る (URLSession は user-discovered の中心 class)。
    refute result.errors.any? { |e| e.include?("GATE 4") && e.include?("URLSession") },
      "T53e: NSURLSession discover で URLSession を含む template を ban しない"
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

  # Phase 7 T3c — async-shape gate. Glue containing `await` MUST follow the
  # DispatchSemaphore + Task { do { try await } catch { captured = error }
  # sema.signal() } + sema.wait() + post-wait raise skeleton from Worked
  # Examples E1-E4. Any deviation is rejected.
  def test_rejects_await_without_dispatch_semaphore
    swift = <<~SWIFT
      import Foundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          Task { _ = try await something() }
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "Foundation", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("async") || e.include?("DispatchSemaphore") }
  end

  def test_accepts_well_formed_async_shape
    swift = <<~SWIFT
      import Foundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let sema = DispatchSemaphore(value: 0)
          var captured: Error?
          Task {
              do { _ = try await something() }
              catch { captured = error }
              sema.signal()
          }
          sema.wait()
          if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }
          return Qnil
      }
    SWIFT
    result = @gates.validate(swift, framework: "Foundation", glue_id: "abc", symbol: "X")
    # Imports / banned-API / shape checks may flag other things, but the
    # async-shape rule itself should be silent.
    assert_empty result.errors.select { |e| e =~ /async|DispatchSemaphore/ }
  end

  # T3c — persistent-block-shape gate. Glue using BoxedBlockHandle MUST also
  # call runtime_callback_register_block_persistent (otherwise the handle is
  # bogus / leaks).
  def test_rejects_boxed_block_handle_without_register_call
    swift = <<~SWIFT
      import Foundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let handle = BoxedBlockHandle(slotId: 1)
          _ = handle
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "Foundation", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("persistent-block") || e.include?("register_block_persistent") }
  end

  # T3c — autoarc-shape gate. Glue boxing into BoxedCFType MUST use
  # Unmanaged.takeRetainedValue() and MUST NOT call CFRelease manually.
  def test_rejects_boxed_cf_type_without_take_retained_value
    swift = <<~SWIFT
      import CoreFoundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let raw: UnsafeRawPointer = UnsafeRawPointer(bitPattern: 1)!
          let boxed = BoxedCFType(retained: raw as AnyObject)
          _ = boxed
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreFoundation", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("autoarc") || e.include?("takeRetainedValue") }
  end

  def test_rejects_manual_cfrelease_in_autoarc_glue
    swift = <<~SWIFT
      import CoreFoundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let raw = MakeCF()
          let boxed = BoxedCFType(retained: Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue())
          CFRelease(raw)
          _ = boxed
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreFoundation", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("CFRelease") }
  end

  # T3c — objc-bridge-shape gate. Manual objc_msgSend is forbidden; use
  # Swift's bridged class names instead (per Worked Examples F1, F2, G).
  def test_rejects_manual_objc_msgSend
    swift = <<~SWIFT
      import Foundation
      @c public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          objc_msgSend(obj, sel, args)
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "Foundation", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("objc_msgSend") }
  end
end

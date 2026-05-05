# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/callback_pillar_codegen"
require "tmpdir"

class TestCallbackPillarCodegen < Test::Unit::TestCase
  def test_generates_pool_slots_for_midi_notify_proc
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "sigs.yml")
      File.write(yaml_path, <<~YAML)
        - token: midiNotifyProc
          c_signature: "void (*)(const MIDINotification *, void *)"
          swift_type: "MIDINotifyProc"
          swift_signature: "@convention(c) (UnsafePointer<MIDINotification>, UnsafeMutableRawPointer?) -> Void"
          arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
          pool_size: 4
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)

      assert_match(/AUTO-GENERATED/, out)
      assert_match(/import CoreMIDI/, out)
      assert_match(/_callback_pillar_midiNotifyProc_slot_0/, out)
      assert_match(/_callback_pillar_midiNotifyProc_slot_3/, out)
      refute_match(/_callback_pillar_midiNotifyProc_slot_4/, out)
      assert_match(/_register_midiNotifyProc/, out)
      assert_match(/_unregister_midiNotifyProc/, out)
      assert_match(/_slots_midiNotifyProc/, out)
      assert_match(/ThreadingBridge\.enqueueFromAppleThread/, out)
      assert_match(/Int64\(message\.pointee\.messageID\.rawValue\)/, out)
    end
  end

  def test_generates_signature_enum
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "sigs.yml")
      File.write(yaml_path, <<~YAML)
        - token: midiNotifyProc
          c_signature: "void (*)(const MIDINotification *, void *)"
          swift_type: "MIDINotifyProc"
          swift_signature: "@convention(c) (UnsafePointer<MIDINotification>, UnsafeMutableRawPointer?) -> Void"
          arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
          pool_size: 2
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)
      assert_match(/enum Signature[^{]*\{[^}]*case midiNotifyProc/m, out)
    end
  end
end

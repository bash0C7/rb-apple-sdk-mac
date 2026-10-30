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
          swift_params: "_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?"
          arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
          pool_size: 4
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)

      assert_no_match(%r{^\s*//}, out)
      assert_no_match(/@_silgen_name/, out)
      assert_match(/@c\(runtime_callback_pillar_register_midi_notify\)/, out)
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
          swift_params: "_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?"
          arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
          pool_size: 2
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)
      assert_match(/enum Signature[^{]*\{[^}]*case midiNotifyProc/m, out)
    end
  end

  def test_generates_for_arbitrary_signature_via_swift_params_field
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "sigs.yml")
      File.write(yaml_path, <<~YAML)
        - token: midiReadProc
          swift_type: "MIDIReadProc"
          swift_params: "_ pktlist: UnsafePointer<MIDIPacketList>, _ readProcRefCon: UnsafeMutableRawPointer?, _ srcConnRefCon: UnsafeMutableRawPointer?"
          arg_marshaller: "Int64(pktlist.pointee.numPackets)"
          pool_size: 2
          frameworks: [CoreMIDI]
      YAML
      out = AppleSDKMac::CallbackPillarCodegen.generate(yaml_path)
      assert_match(/_callback_pillar_midiReadProc_slot_0/, out)
      assert_match(/_register_midiReadProc/, out)
      assert_match(/_unregister_midiReadProc/, out)
      assert_match(/_ pktlist: UnsafePointer<MIDIPacketList>/, out)
      assert_match(/_ readProcRefCon: UnsafeMutableRawPointer\?/, out)
      assert_match(/_ srcConnRefCon: UnsafeMutableRawPointer\?/, out)
      assert_match(/Int64\(pktlist\.pointee\.numPackets\)/, out)
      refute_match(/MIDINotification/, out)
    end
  end
end

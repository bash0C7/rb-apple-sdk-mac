// AUTO-GENERATED — do not edit. Source: callback_signatures.yml.

import Foundation
import CoreMIDI

extension CallbackPillar {
    public enum Signature: String {
        case midiNotifyProc
    }
}

// === midiNotifyProc, pool_size=4 ===
nonisolated(unsafe) fileprivate var _slots_midiNotifyProc: [UInt64?] = Array(repeating: nil, count: 4)
fileprivate let _slots_midiNotifyProc_lock = NSLock()

@_silgen_name("_callback_pillar_midiNotifyProc_slot_0")
public func _callback_pillar_midiNotifyProc_slot_0(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let procId = _slots_midiNotifyProc[0] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_1")
public func _callback_pillar_midiNotifyProc_slot_1(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let procId = _slots_midiNotifyProc[1] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_2")
public func _callback_pillar_midiNotifyProc_slot_2(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let procId = _slots_midiNotifyProc[2] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_3")
public func _callback_pillar_midiNotifyProc_slot_3(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let procId = _slots_midiNotifyProc[3] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

extension CallbackPillar {
    static func _register_midiNotifyProc(procId: UInt64) -> (slot: Int, fnptr: MIDINotifyProc)? {
        _slots_midiNotifyProc_lock.lock()
        defer { _slots_midiNotifyProc_lock.unlock() }
        for (i, v) in _slots_midiNotifyProc.enumerated() where v == nil {
            _slots_midiNotifyProc[i] = procId
            let fnptrs: [MIDINotifyProc] = [
                _callback_pillar_midiNotifyProc_slot_0,
                _callback_pillar_midiNotifyProc_slot_1,
                _callback_pillar_midiNotifyProc_slot_2,
                _callback_pillar_midiNotifyProc_slot_3,
            ]
            return (i, fnptrs[i])
        }
        return nil
    }

    static func _unregister_midiNotifyProc(slot: Int) {
        _slots_midiNotifyProc_lock.lock()
        defer { _slots_midiNotifyProc_lock.unlock() }
        _slots_midiNotifyProc[slot] = nil
    }
}


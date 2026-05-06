// AUTO-GENERATED — do not edit. Source: callback_signatures.yml.

import Foundation
import CoreMIDI

extension CallbackPillar {
    public enum Signature: String {
        case midiNotifyProc
        case midiReadProc
    }
}

// === midiNotifyProc, pool_size=4 ===
nonisolated(unsafe) fileprivate var _slots_midiNotifyProc: [UInt64?] = Array(repeating: nil, count: 4)
fileprivate let _slots_midiNotifyProc_lock = NSLock()

@_silgen_name("_callback_pillar_midiNotifyProc_slot_0")
public func _callback_pillar_midiNotifyProc_slot_0(_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiNotifyProc[0] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_1")
public func _callback_pillar_midiNotifyProc_slot_1(_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiNotifyProc[1] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_2")
public func _callback_pillar_midiNotifyProc_slot_2(_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiNotifyProc[2] else { return }
    let arg: Int64 = Int64(message.pointee.messageID.rawValue)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiNotifyProc_slot_3")
public func _callback_pillar_midiNotifyProc_slot_3(_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?) {
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

@c
public func runtime_callback_pillar_register_midi_notify(_ procId: UInt64) -> Int32 {
    guard let r = CallbackPillar._register_midiNotifyProc(procId: procId) else { return -1 }
    return Int32(r.slot)
}

@c
public func runtime_callback_pillar_get_midi_notify_fnptr(_ slot: Int32) -> UInt64 {
    let fnptrs: [MIDINotifyProc] = [
        _callback_pillar_midiNotifyProc_slot_0,
        _callback_pillar_midiNotifyProc_slot_1,
        _callback_pillar_midiNotifyProc_slot_2,
        _callback_pillar_midiNotifyProc_slot_3,
    ]
    let p = unsafeBitCast(fnptrs[Int(slot)], to: UnsafeRawPointer.self)
    return UInt64(UInt(bitPattern: p))
}

@c
public func runtime_callback_pillar_unregister_midi_notify(_ slot: Int32) {
    CallbackPillar._unregister_midiNotifyProc(slot: Int(slot))
}

// === midiReadProc, pool_size=4 ===
nonisolated(unsafe) fileprivate var _slots_midiReadProc: [UInt64?] = Array(repeating: nil, count: 4)
fileprivate let _slots_midiReadProc_lock = NSLock()

@_silgen_name("_callback_pillar_midiReadProc_slot_0")
public func _callback_pillar_midiReadProc_slot_0(_ pktlist: UnsafePointer<MIDIPacketList>, _ readProcRefCon: UnsafeMutableRawPointer?, _ srcConnRefCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiReadProc[0] else { return }
    let arg: Int64 = Int64(pktlist.pointee.numPackets)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiReadProc_slot_1")
public func _callback_pillar_midiReadProc_slot_1(_ pktlist: UnsafePointer<MIDIPacketList>, _ readProcRefCon: UnsafeMutableRawPointer?, _ srcConnRefCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiReadProc[1] else { return }
    let arg: Int64 = Int64(pktlist.pointee.numPackets)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiReadProc_slot_2")
public func _callback_pillar_midiReadProc_slot_2(_ pktlist: UnsafePointer<MIDIPacketList>, _ readProcRefCon: UnsafeMutableRawPointer?, _ srcConnRefCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiReadProc[2] else { return }
    let arg: Int64 = Int64(pktlist.pointee.numPackets)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@_silgen_name("_callback_pillar_midiReadProc_slot_3")
public func _callback_pillar_midiReadProc_slot_3(_ pktlist: UnsafePointer<MIDIPacketList>, _ readProcRefCon: UnsafeMutableRawPointer?, _ srcConnRefCon: UnsafeMutableRawPointer?) {
    guard let procId = _slots_midiReadProc[3] else { return }
    let arg: Int64 = Int64(pktlist.pointee.numPackets)
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

extension CallbackPillar {
    static func _register_midiReadProc(procId: UInt64) -> (slot: Int, fnptr: MIDIReadProc)? {
        _slots_midiReadProc_lock.lock()
        defer { _slots_midiReadProc_lock.unlock() }
        for (i, v) in _slots_midiReadProc.enumerated() where v == nil {
            _slots_midiReadProc[i] = procId
            let fnptrs: [MIDIReadProc] = [
                _callback_pillar_midiReadProc_slot_0,
                _callback_pillar_midiReadProc_slot_1,
                _callback_pillar_midiReadProc_slot_2,
                _callback_pillar_midiReadProc_slot_3,
            ]
            return (i, fnptrs[i])
        }
        return nil
    }

    static func _unregister_midiReadProc(slot: Int) {
        _slots_midiReadProc_lock.lock()
        defer { _slots_midiReadProc_lock.unlock() }
        _slots_midiReadProc[slot] = nil
    }
}

@c
public func runtime_callback_pillar_register_midi_read(_ procId: UInt64) -> Int32 {
    guard let r = CallbackPillar._register_midiReadProc(procId: procId) else { return -1 }
    return Int32(r.slot)
}

@c
public func runtime_callback_pillar_get_midi_read_fnptr(_ slot: Int32) -> UInt64 {
    let fnptrs: [MIDIReadProc] = [
        _callback_pillar_midiReadProc_slot_0,
        _callback_pillar_midiReadProc_slot_1,
        _callback_pillar_midiReadProc_slot_2,
        _callback_pillar_midiReadProc_slot_3,
    ]
    let p = unsafeBitCast(fnptrs[Int(slot)], to: UnsafeRawPointer.self)
    return UInt64(UInt(bitPattern: p))
}

@c
public func runtime_callback_pillar_unregister_midi_read(_ slot: Int32) {
    CallbackPillar._unregister_midiReadProc(slot: Int(slot))
}


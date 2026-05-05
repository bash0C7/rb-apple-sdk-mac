import Foundation
import CoreMIDI

@c
public func runtime_ref_retain_test(_ rubyObjectId: UInt64) -> UInt32 {
    let box = TestObjectIDBox(id: rubyObjectId)
    return RefTable.retain(box)
}

@c
public func runtime_ref_lookup_test(_ handle: UInt32) -> UInt64 {
    guard let box = RefTable.lookup(handle, as: TestObjectIDBox.self) else {
        return 0
    }
    return box.id
}

@c
public func runtime_ref_release(_ handle: UInt32) {
    RefTable.release(handle)
}

@c
public func runtime_marshal_string_round_trip(
    _ input: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let s = Marshal.swiftString(fromCString: input)
    return Marshal.cString(fromSwift: s)
}

@c
public func runtime_marshal_int_round_trip(_ value: Int64) -> Int64 {
    return value
}

@c
public func runtime_marshal_array_count(_ count: Int64) -> Int64 {
    return count
}

@c
public func runtime_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

@c
public func runtime_raise_request(
    _ kind: Int32,
    _ message: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    return strdup(String(cString: message))!
}

@c
public func runtime_threading_enqueue(_ procId: UInt64, _ arg: Int64) {
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@c
public func runtime_threading_poll(_ timeoutSeconds: Double) -> Int64 {
    return Int64(ThreadingBridge.drain(timeoutSeconds: timeoutSeconds))
}

@c
public func runtime_callback_set_dispatcher(
    _ fn: @convention(c) (UInt64, Int64) -> Void
) {
    CallbackBridge.rubyDispatcher = fn
}

@c
public func runtime_callback_invoke(_ procId: UInt64, _ arg: Int64) {
    CallbackBridge.dispatch(procId: procId, arg: arg)
}

@c
public func runtime_arc_counter_init() -> UInt32 {
    return ARCBridge.makeCounter()
}

@c
public func runtime_arc_counter_bump(_ handle: UInt32) {
    ARCBridge.bump(handle)
}

@c
public func runtime_arc_counter_value(_ handle: UInt32) -> Int64 {
    return ARCBridge.value(handle)
}

@c
public func runtime_async_test_sleep_and_double(_ millis: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
            return millis * 2
        }
    } catch {
        return -1
    }
}

@c
public func runtime_runloop_pump(_ timeoutSeconds: Double) {
    RunLoopBridge.pump(timeoutSeconds: timeoutSeconds)
}

@c
public func runtime_conformance_register(_ rubyTableId: UInt64) -> UInt32 {
    return ConformanceBridge.register(rubyTableId: rubyTableId)
}

@c
public func runtime_conformance_release(_ handle: UInt32) {
    ConformanceBridge.release(handle)
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

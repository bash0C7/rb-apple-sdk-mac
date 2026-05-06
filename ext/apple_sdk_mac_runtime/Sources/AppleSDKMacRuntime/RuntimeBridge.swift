import Foundation
import CoreMIDI

// Proc registry — Ruby Hash VALUE owned by the runtime Swift dylib so that
// both the Ruby C extension (loaded RTLD_LOCAL) and per-symbol glue dylibs
// (each loaded RTLD_LOCAL) reach the SAME hash via a flat-namespace symbol.
//
// rb_define_variable + rb_gv_get does NOT work here under Ruby::Box: the
// $__...-named global is a Box-wrapped view that does not share storage with
// the C-static VALUE the dispatcher reads. Confirmed empirically: a Ruby
// `$reg[k] = v` mutation is invisible to a C-side `rb_hash_lookup(proc_reg, k)`.
nonisolated(unsafe) public var appleProcRegistry: UInt = 0

@_silgen_name("rb_hash_new")
private func _rb_hash_new() -> UInt
@_silgen_name("rb_global_variable")
private func _rb_global_variable(_ p: UnsafeMutablePointer<UInt>)

@c
public func runtime_proc_registry_init() {
    appleProcRegistry = _rb_hash_new()
    _rb_global_variable(&appleProcRegistry)
}

@c
public func runtime_proc_registry_get() -> UInt {
    return appleProcRegistry
}

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
public func runtime_async_test_taskgroup_double(_ msA: Int64, _ msB: Int64, _ msC: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await withThrowingTaskGroup(of: Int64.self) { group in
                for ms in [msA, msB, msC] {
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                        return ms * 2
                    }
                }
                var total: Int64 = 0
                for try await v in group { total += v }
                return total
            }
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

// runtime_callback_pillar_* wrappers (register / get_fnptr / unregister) are
// now auto-generated per signature in CallbackPillarGenerated.swift from
// callback_signatures.yml. To add a new C function-pointer signature:
// edit callback_signatures.yml, then `rake runtime:codegen_callback_pillar`.

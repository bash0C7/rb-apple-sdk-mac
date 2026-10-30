import Foundation

/// The Ruby `Hash` that maps proc ids to Ruby procs, shared by the C extension and every glue dylib.
nonisolated(unsafe) public var appleProcRegistry: UInt = 0

@_silgen_name("rb_hash_new")
private func _rb_hash_new() -> UInt
@_silgen_name("rb_global_variable")
private func _rb_global_variable(_ p: UnsafeMutablePointer<UInt>)

/// Creates ``appleProcRegistry`` and registers it as a GC root.
@c(runtime_proc_registry_init)
public func runtime_proc_registry_init() {
    appleProcRegistry = _rb_hash_new()
    _rb_global_variable(&appleProcRegistry)
}

/// Returns ``appleProcRegistry``.
@c(runtime_proc_registry_get)
public func runtime_proc_registry_get() -> UInt {
    appleProcRegistry
}

@c(runtime_ref_retain_test)
public func runtime_ref_retain_test(_ rubyObjectId: UInt64) -> UInt32 {
    RefTable.retain(TestObjectIDBox(id: rubyObjectId))
}

@c(runtime_ref_lookup_test)
public func runtime_ref_lookup_test(_ handle: UInt32) -> UInt64 {
    RefTable.lookup(handle, as: TestObjectIDBox.self)?.id ?? 0
}

@c(runtime_ref_release)
public func runtime_ref_release(_ handle: UInt32) {
    RefTable.release(handle)
}

@c(runtime_marshal_string_round_trip)
public func runtime_marshal_string_round_trip(
    _ input: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    Marshal.cString(fromSwift: Marshal.swiftString(fromCString: input))
}

@c(runtime_marshal_int_round_trip)
public func runtime_marshal_int_round_trip(_ value: Int64) -> Int64 {
    value
}

@c(runtime_marshal_array_count)
public func runtime_marshal_array_count(_ count: Int64) -> Int64 {
    count
}

/// Releases a string returned by a `runtime_*` function.
///
/// - Parameter ptr: A buffer allocated with `strdup`, or `nil`.
@c(runtime_string_free)
public func runtime_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

@c(runtime_raise_request)
public func runtime_raise_request(
    _ kind: Int32,
    _ message: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    strdup(String(cString: message))!
}

/// Queues a one-argument callback for the Ruby thread; see ``ThreadingBridge/enqueueFromAppleThread(procId:arg:)``.
@c(runtime_threading_enqueue)
public func runtime_threading_enqueue(_ procId: UInt64, _ arg: Int64) {
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

/// Queues a three-argument callback for the Ruby thread; see ``ThreadingBridge/enqueueFromAppleThread3(procId:_:_:_:)``.
@c(runtime_threading_enqueue_3)
public func runtime_threading_enqueue_3(_ procId: UInt64, _ a: Int64, _ b: Int64, _ c: Int64) {
    ThreadingBridge.enqueueFromAppleThread3(procId: procId, a, b, c)
}

/// Dispatches queued callbacks until `timeoutSeconds` elapses.
///
/// - Returns: The number of callbacks dispatched.
@c(runtime_threading_poll)
public func runtime_threading_poll(_ timeoutSeconds: Double) -> Int64 {
    Int64(ThreadingBridge.drain(timeoutSeconds: timeoutSeconds))
}

/// Installs the C function that calls a one-argument Ruby proc.
@c(runtime_callback_set_dispatcher)
public func runtime_callback_set_dispatcher(
    _ fn: @convention(c) (UInt64, Int64) -> Void
) {
    CallbackBridge.rubyDispatcher = fn
}

/// Installs the C function that calls a Ruby proc with `count` arguments.
@c(runtime_callback_set_dispatcher_n)
public func runtime_callback_set_dispatcher_n(
    _ fn: @convention(c) (UInt64, Int32, UnsafePointer<Int64>) -> Void
) {
    CallbackBridge.rubyDispatcherN = fn
}

@c(runtime_callback_invoke)
public func runtime_callback_invoke(_ procId: UInt64, _ arg: Int64) {
    CallbackBridge.dispatch(procId: procId, arg: arg)
}

@c(runtime_arc_counter_init)
public func runtime_arc_counter_init() -> UInt32 {
    ARCBridge.makeCounter()
}

@c(runtime_arc_counter_bump)
public func runtime_arc_counter_bump(_ handle: UInt32) {
    ARCBridge.bump(handle)
}

@c(runtime_arc_counter_value)
public func runtime_arc_counter_value(_ handle: UInt32) -> Int64 {
    ARCBridge.value(handle)
}

@c(runtime_async_test_sleep_and_double)
public func runtime_async_test_sleep_and_double(_ millis: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await Task.sleep(for: .milliseconds(millis))
            return millis * 2
        }
    } catch {
        return -1
    }
}

@_silgen_name("rb_funcallv")
private func _rb_funcallv(_ recv: UInt, _ mid: Int, _ argc: Int32, _ argv: UnsafePointer<UInt>?) -> UInt

@_silgen_name("rb_intern")
private func _rb_intern(_ name: UnsafePointer<CChar>) -> Int

@_silgen_name("rb_num2ll")
private func _rb_num2ll(_ v: UInt) -> Int64

/// Returns the length of a Ruby `Array`.
///
/// Glue dylibs resolve this symbol through the flat namespace, which cannot reach the `RARRAY_LEN` macro or the C extension bundle.
///
/// - Parameter ary: A Ruby `Array` `VALUE`.
/// - Returns: The result of `ary.length`.
@c(runtime_rb_array_len)
public func runtime_rb_array_len(_ ary: UInt) -> Int {
    let lengthId = "length".withCString { _rb_intern($0) }
    return Int(_rb_num2ll(_rb_funcallv(ary, lengthId, 0, nil)))
}

@c(runtime_async_test_taskgroup_double)
public func runtime_async_test_taskgroup_double(_ msA: Int64, _ msB: Int64, _ msC: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await withThrowingTaskGroup(of: Int64.self) { group in
                for ms in [msA, msB, msC] {
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(ms))
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

/// Runs the current thread's run loop in the default mode for up to `timeoutSeconds`, returning after the first handled source.
@c(runtime_runloop_pump)
public func runtime_runloop_pump(_ timeoutSeconds: Double) {
    RunLoopBridge.pump(timeoutSeconds: timeoutSeconds)
}

@c(runtime_conformance_register)
public func runtime_conformance_register(_ rubyTableId: UInt64) -> UInt32 {
    ConformanceBridge.register(rubyTableId: rubyTableId)
}

@c(runtime_conformance_release)
public func runtime_conformance_release(_ handle: UInt32) {
    ConformanceBridge.release(handle)
}

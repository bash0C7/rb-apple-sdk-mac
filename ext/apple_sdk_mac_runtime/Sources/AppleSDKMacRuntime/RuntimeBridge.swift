import Foundation

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

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

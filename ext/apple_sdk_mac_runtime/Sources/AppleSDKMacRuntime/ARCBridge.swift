import Foundation

/// Release counters that observe object lifetimes from Ruby.
public enum ARCBridge {
    public final class ReleaseCounter {
        nonisolated(unsafe) private var count: Int64 = 0
        let queue = DispatchQueue(label: "ARCBridge.ReleaseCounter")
        func bump() { queue.sync { count += 1 } }
        func value() -> Int64 { queue.sync { count } }
    }

    private static let queue = DispatchQueue(label: "ARCBridge.counters")
    nonisolated(unsafe) private static var counters: [UInt32: ReleaseCounter] = [:]
    nonisolated(unsafe) private static var next: UInt32 = 1

    /// Creates a counter and returns its handle.
    public static func makeCounter() -> UInt32 {
        queue.sync {
            let h = next
            next += 1
            counters[h] = ReleaseCounter()
            return h
        }
    }

    /// Increments the counter `handle`.
    public static func bump(_ handle: UInt32) {
        queue.sync { counters[handle] }?.bump()
    }

    /// Returns the value of the counter `handle`, or `0` for an unknown handle.
    public static func value(_ handle: UInt32) -> Int64 {
        queue.sync { counters[handle]?.value() ?? 0 }
    }
}

/// Holds a Core Foundation object returned under the Create rule and releases it on deinitialization.
public final class BoxedCFType {
    public let retained: AnyObject
    public init(retained: AnyObject) { self.retained = retained }
}

nonisolated(unsafe) fileprivate var _boxedCFTypeRegistry: Set<UInt> = []
fileprivate let _boxedCFTypeRegistryLock = NSLock()

/// Wraps a +1 Core Foundation object in a ``BoxedCFType``.
///
/// - Parameter raw: The bit pattern of a Core Foundation object returned under the Create rule.
/// - Returns: The bit pattern of a retained ``BoxedCFType`` that owns the object.
@c(runtime_arc_box_cftype)
public func runtime_arc_box_cftype(_ raw: UInt) -> UInt {
    let unmanaged = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(bitPattern: raw)!)
    let boxed = BoxedCFType(retained: unmanaged.takeRetainedValue())
    let pointer = UInt(bitPattern: Unmanaged.passRetained(boxed).toOpaque())
    _boxedCFTypeRegistryLock.withLock {
        _ = _boxedCFTypeRegistry.insert(pointer)
    }
    return pointer
}

/// Returns the Core Foundation object held by a box from ``runtime_arc_box_cftype(_:)``.
///
/// - Parameter raw: A bit pattern that may or may not be a ``BoxedCFType``.
/// - Returns: The bit pattern of the boxed object, or `0` when `raw` is not a box.
@c(runtime_arc_unbox_cftype)
public func runtime_arc_unbox_cftype(_ raw: UInt) -> UInt {
    let isBoxed = _boxedCFTypeRegistryLock.withLock { _boxedCFTypeRegistry.contains(raw) }
    guard isBoxed else { return 0 }
    let box = Unmanaged<BoxedCFType>.fromOpaque(UnsafeRawPointer(bitPattern: raw)!).takeUnretainedValue()
    return UInt(bitPattern: Unmanaged.passUnretained(box.retained).toOpaque())
}

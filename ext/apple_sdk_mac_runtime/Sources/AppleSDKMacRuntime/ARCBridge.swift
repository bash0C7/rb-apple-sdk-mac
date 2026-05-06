import Foundation

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

    public static func makeCounter() -> UInt32 {
        queue.sync {
            let h = next; next += 1
            counters[h] = ReleaseCounter()
            return h
        }
    }

    public static func bump(_ handle: UInt32) {
        queue.sync { counters[handle] }?.bump()
    }

    public static func value(_ handle: UInt32) -> Int64 {
        queue.sync { counters[handle]?.value() ?? 0 }
    }
}

// === Phase 7 T4: CF Create-rule auto-ARC ===
//
// CF types returned by Create-rule APIs (CFStringCreateWithCString,
// CGImageCreateWithJPEGDataProvider, etc.) come +1-retained. Wrapping the
// raw pointer in a BoxedCFType class brings them under Swift ARC: the Box's
// deinit releases the CF reference, so user code never calls CFRelease.
public final class BoxedCFType {
    public let retained: AnyObject
    public init(retained: AnyObject) { self.retained = retained }
}

// Glue Swift can't import AppleSDKMacRuntime (LLM rule 3) and so can't
// instantiate BoxedCFType directly. This @c entry point performs the
// Unmanaged.takeRetainedValue + BoxedCFType wrap inside the runtime dylib
// and returns the raw bit-pattern of a passRetained Box pointer that the
// glue marshals into a Ruby Integer.
@c
public func runtime_arc_box_cftype(_ raw: UInt) -> UInt {
    let opaq = OpaquePointer(bitPattern: raw)!
    let unmanaged = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(opaq))
    let boxed = BoxedCFType(retained: unmanaged.takeRetainedValue())
    return UInt(bitPattern: Unmanaged.passRetained(boxed).toOpaque())
}

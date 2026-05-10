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

// === CF Create-rule auto-ARC ===
//
// CF types returned by Create-rule APIs (CFStringCreateWithCString,
// CGImageCreateWithJPEGDataProvider, etc.) come +1-retained. Wrapping the
// raw pointer in a BoxedCFType class brings them under Swift ARC: the Box's
// deinit releases the CF reference, so user code never calls CFRelease.
public final class BoxedCFType {
    public let retained: AnyObject
    public init(retained: AnyObject) { self.retained = retained }
}

// Autoarc box pointer の registry。 runtime_arc_box_cftype が登録、
// runtime_arc_unbox_cftype が照合に使う。 box でない raw CF pointer が
// unbox に来たケース (round-trip 経路で raw を直接渡された場合) を 0 で
// 戻して fall-back させる contract に必要。
nonisolated(unsafe) fileprivate var _boxedCFTypeRegistry: Set<UInt> = []
fileprivate let _boxedCFTypeRegistryLock = NSLock()

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
    let pointer = UInt(bitPattern: Unmanaged.passRetained(boxed).toOpaque())
    _boxedCFTypeRegistryLock.lock()
    _boxedCFTypeRegistry.insert(pointer)
    _boxedCFTypeRegistryLock.unlock()
    return pointer
}

// Autoarc box pointer から内部の CF object pointer を取り出す。
// Apple.discover で `cftype_ref` param に autoarc box を渡された CF API が
// 元 CF pointer を必要とする (CFStringGetLength, CFStringGetCString, ...)
// ためのアンマーシャラ。 input が registry に無い (raw CF pointer 直渡し
// など) は 0 を返して、 glue 側で raw input を fall-back で使えるようにする。
@c
public func runtime_arc_unbox_cftype(_ raw: UInt) -> UInt {
    _boxedCFTypeRegistryLock.lock()
    let isBoxed = _boxedCFTypeRegistry.contains(raw)
    _boxedCFTypeRegistryLock.unlock()
    guard isBoxed else { return 0 }
    let opaq = OpaquePointer(bitPattern: raw)!
    let box = Unmanaged<BoxedCFType>.fromOpaque(UnsafeRawPointer(opaq)).takeUnretainedValue()
    let inner = Unmanaged.passUnretained(box.retained).toOpaque()
    return UInt(bitPattern: inner)
}

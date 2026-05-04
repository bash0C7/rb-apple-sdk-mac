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

import Foundation

public enum ConformanceBridge {
    private struct HandlerTable {
        let rubyTableId: UInt64
    }

    private static let queue = DispatchQueue(label: "ConformanceBridge.tables")
    nonisolated(unsafe) private static var tables: [UInt32: HandlerTable] = [:]
    nonisolated(unsafe) private static var next: UInt32 = 1

    public static func register(rubyTableId: UInt64) -> UInt32 {
        queue.sync {
            let h = next; next += 1
            tables[h] = HandlerTable(rubyTableId: rubyTableId)
            return h
        }
    }

    public static func release(_ handle: UInt32) {
        _ = queue.sync { tables.removeValue(forKey: handle) }
    }

    public static func lookup(_ handle: UInt32) -> UInt64? {
        queue.sync { tables[handle]?.rubyTableId }
    }
}

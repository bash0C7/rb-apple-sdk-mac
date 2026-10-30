import Foundation

/// Handles to Ruby handler tables that implement protocol conformances.
public enum ConformanceBridge {
    private struct HandlerTable {
        let rubyTableId: UInt64
    }

    private static let queue = DispatchQueue(label: "ConformanceBridge.tables")
    nonisolated(unsafe) private static var tables: [UInt32: HandlerTable] = [:]
    nonisolated(unsafe) private static var next: UInt32 = 1

    /// Registers the Ruby handler table `rubyTableId` and returns its handle.
    public static func register(rubyTableId: UInt64) -> UInt32 {
        queue.sync {
            let h = next
            next += 1
            tables[h] = HandlerTable(rubyTableId: rubyTableId)
            return h
        }
    }

    /// Removes the table `handle`.
    public static func release(_ handle: UInt32) {
        _ = queue.sync { tables.removeValue(forKey: handle) }
    }

    /// Returns the Ruby table id of `handle`, or `nil` for an unknown handle.
    public static func lookup(_ handle: UInt32) -> UInt64? {
        queue.sync { tables[handle]?.rubyTableId }
    }
}

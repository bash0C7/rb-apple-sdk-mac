import Foundation

public enum RefTable {
    public typealias RefHandle = UInt32

    private static let queue = DispatchQueue(label: "AppleSDKMacRuntime.RefTable")
    nonisolated(unsafe) private static var table: [RefHandle: AnyObject] = [:]
    nonisolated(unsafe) private static var nextHandle: RefHandle = 1

    public static func retain(_ obj: AnyObject) -> RefHandle {
        queue.sync {
            let h = nextHandle
            nextHandle &+= 1
            table[h] = obj
            return h
        }
    }

    public static func release(_ handle: RefHandle) {
        _ = queue.sync { table.removeValue(forKey: handle) }
    }

    public static func lookup<T>(_ handle: RefHandle, as: T.Type) -> T? {
        queue.sync { table[handle] as? T }
    }
}

public final class TestObjectIDBox: NSObject {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

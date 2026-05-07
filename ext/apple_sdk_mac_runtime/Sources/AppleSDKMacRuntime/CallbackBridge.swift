import Foundation

public enum CallbackBridge {
    nonisolated(unsafe) public static var rubyDispatcher: (@convention(c) (UInt64, Int64) -> Void)?
    // T53a — N-arg dispatcher for typed multi-arg blocks. Ruby C ext registers
    // ruby_callback_dispatcher_n via runtime_callback_set_dispatcher_n.
    nonisolated(unsafe) public static var rubyDispatcherN: (@convention(c) (UInt64, Int32, UnsafePointer<Int64>) -> Void)?

    public static func dispatch(procId: UInt64, arg: Int64) {
        rubyDispatcher?(procId, arg)
    }

    public static func dispatchN(procId: UInt64, args: [Int64]) {
        if let n = rubyDispatcherN {
            args.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    n(procId, Int32(args.count), base)
                }
            }
        } else if let single = rubyDispatcher {
            // Backward compat: 1-arg path when N-arg dispatcher hasn't registered
            single(procId, args.first ?? 0)
        }
    }
}

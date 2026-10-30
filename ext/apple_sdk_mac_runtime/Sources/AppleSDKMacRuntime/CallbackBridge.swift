import Foundation

/// The C functions that call Ruby procs, installed by the C extension.
public enum CallbackBridge {
    /// Calls a Ruby proc with one argument.
    nonisolated(unsafe) public static var rubyDispatcher: (@convention(c) (UInt64, Int64) -> Void)?
    /// Calls a Ruby proc with `count` arguments.
    nonisolated(unsafe) public static var rubyDispatcherN: (@convention(c) (UInt64, Int32, UnsafePointer<Int64>) -> Void)?

    /// Calls the Ruby proc `procId` with `arg` through ``rubyDispatcher``.
    public static func dispatch(procId: UInt64, arg: Int64) {
        rubyDispatcher?(procId, arg)
    }

    /// Calls the Ruby proc `procId` with `args` through ``rubyDispatcherN``.
    public static func dispatchN(procId: UInt64, args: [Int64]) {
        guard let dispatcher = rubyDispatcherN else { return }
        args.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                dispatcher(procId, Int32(args.count), base)
            }
        }
    }
}

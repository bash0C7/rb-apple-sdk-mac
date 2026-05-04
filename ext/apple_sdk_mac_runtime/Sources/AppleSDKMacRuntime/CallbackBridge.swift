import Foundation

public enum CallbackBridge {
    nonisolated(unsafe) public static var rubyDispatcher: (@convention(c) (UInt64, Int64) -> Void)?

    public static func dispatch(procId: UInt64, arg: Int64) {
        rubyDispatcher?(procId, arg)
    }
}

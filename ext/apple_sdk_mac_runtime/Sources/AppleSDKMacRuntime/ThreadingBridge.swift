import Foundation

/// A queue that carries callbacks from Apple threads to the Ruby thread.
public enum ThreadingBridge {
    private struct Pending {
        let procId: UInt64
        let args: [Int64]
    }

    private static let queue = DispatchQueue(label: "ThreadingBridge.lockfree")
    nonisolated(unsafe) private static var pending: [Pending] = []

    /// Queues a call of the Ruby proc `procId` with one argument.
    public static func enqueueFromAppleThread(procId: UInt64, arg: Int64) {
        queue.sync { pending.append(Pending(procId: procId, args: [arg])) }
    }

    /// Queues a call of the Ruby proc `procId` with three arguments, such as the raw pointers of a `(Data?, URLResponse?, Error?)` completion handler (`0` for `nil`).
    public static func enqueueFromAppleThread3(procId: UInt64, _ a: Int64, _ b: Int64, _ c: Int64) {
        queue.sync { pending.append(Pending(procId: procId, args: [a, b, c])) }
    }

    /// Dispatches queued calls on the calling thread until `timeoutSeconds` elapses.
    ///
    /// - Returns: The number of calls dispatched.
    public static func drain(timeoutSeconds: Double) -> Int {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var drained = 0
        while Date() < deadline {
            let next = queue.sync { () -> Pending? in
                pending.isEmpty ? nil : pending.removeFirst()
            }
            guard let p = next else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            CallbackBridge.dispatchN(procId: p.procId, args: p.args)
            drained += 1
        }
        return drained
    }
}

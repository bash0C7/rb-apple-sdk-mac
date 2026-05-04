import Foundation

public enum ThreadingBridge {
    private struct Pending {
        let procId: UInt64
        let arg: Int64
    }

    private static let queue = DispatchQueue(label: "ThreadingBridge.lockfree")
    nonisolated(unsafe) private static var pending: [Pending] = []

    public static func enqueueFromAppleThread(procId: UInt64, arg: Int64) {
        queue.sync { pending.append(Pending(procId: procId, arg: arg)) }
    }

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
            CallbackBridge.dispatch(procId: p.procId, arg: p.arg)
            drained += 1
        }
        return drained
    }
}

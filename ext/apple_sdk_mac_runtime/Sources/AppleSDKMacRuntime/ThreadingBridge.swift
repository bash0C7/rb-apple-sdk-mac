import Foundation

public enum ThreadingBridge {
    private struct Pending {
        let procId: UInt64
        let args: [Int64]
    }

    private static let queue = DispatchQueue(label: "ThreadingBridge.lockfree")
    nonisolated(unsafe) private static var pending: [Pending] = []

    public static func enqueueFromAppleThread(procId: UInt64, arg: Int64) {
        queue.sync { pending.append(Pending(procId: procId, args: [arg])) }
    }

    // N-arg dispatch path for typed Hash-form :block_persistent. URLSession の
    // `(Data?, URLResponse?, Error?) -> Void` のような multi-arg escaping block を
    // Ruby callback に届ける。 各 Optional は raw pointer (Int64, nil → 0) に変換
    // 済みで渡される。
    public static func enqueueFromAppleThread3(procId: UInt64, _ a: Int64, _ b: Int64, _ c: Int64) {
        queue.sync { pending.append(Pending(procId: procId, args: [a, b, c])) }
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
            CallbackBridge.dispatchN(procId: p.procId, args: p.args)
            drained += 1
        }
        return drained
    }
}

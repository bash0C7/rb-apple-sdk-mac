import Foundation

public enum AsyncBridge {
    public static func runSync<T>(_ task: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task {
            defer { semaphore.signal() }
            do {
                let v = try await task()
                result = .success(v)
            } catch {
                result = .failure(error)
            }
        }
        semaphore.wait()
        switch result! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}

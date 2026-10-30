import Foundation

/// Runs Swift concurrency work from synchronous C entry points.
public enum AsyncBridge {
    /// Runs `task` in a new `Task` and blocks the calling thread until it finishes.
    ///
    /// - Parameter task: The asynchronous work.
    /// - Returns: The value `task` returns.
    /// - Throws: The error `task` throws.
    public static func runSync<T>(_ task: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task {
            defer { semaphore.signal() }
            do {
                result = .success(try await task())
            } catch {
                result = .failure(error)
            }
        }
        semaphore.wait()
        return try result!.get()
    }
}

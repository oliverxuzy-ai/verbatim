import Foundation

nonisolated struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Timed out after \(Int(seconds)) s" }
}

/// Runs `operation` but gives up after `seconds`, even if the operation never
/// honours cancellation (some system speech APIs can hang on odd input). A
/// task group would wait for its stuck child; this returns and abandons it.
nonisolated func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let finished = Locked(false)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let value = try await operation()
                if finished.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: value) }
            } catch {
                if finished.withLock({ done in defer { done = true }; return !done }) { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if finished.withLock({ done in defer { done = true }; return !done }) {
                work.cancel()
                continuation.resume(throwing: TimeoutError(seconds: seconds))
            }
        }
    }
}

import Foundation

/// Admission is synchronous, so callers can reject frames before copying buffers.
/// Accepted jobs finish even if their caller is cancelled. Drain includes delivery
/// of completion callbacks, not just the underlying file writes.
@MainActor
public final class BoundedCaptureWriter {
    public let capacity: Int
    public private(set) var pendingCount = 0
    private var jobs: [@MainActor () -> Void] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(capacity: Int = 3) { precondition(capacity > 0); self.capacity = capacity }
    public func canAccept(_ count: Int = 1) -> Bool { pendingCount + count <= capacity }

    @discardableResult
    public func submit<Value: Sendable>(
        operation: @escaping @Sendable () throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) -> Bool {
        guard canAccept() else { return false }
        pendingCount += 1
        let start: @MainActor () -> Void = { [self] in
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try operation() }
                }.value
                completion(result)
                pendingCount -= 1
                if !jobs.isEmpty { jobs.removeFirst()() }
                else {
                    let ready = waiters
                    waiters.removeAll()
                    ready.forEach { $0.resume() }
                }
            }
        }
        if pendingCount == 1 { start() } else { jobs.append(start) }
        return true
    }

    public func drain() async {
        guard pendingCount > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

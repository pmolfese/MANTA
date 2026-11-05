import Foundation
import Testing
@testable import MANTACore

@MainActor
struct BoundedCaptureWriterTests {
    @Test func boundsAdmissionRunsOffMainAndDrainsInOrderIncludingFailures() async {
        let writer = BoundedCaptureWriter(capacity: 3)
        let gate = DispatchSemaphore(value: 0)
        var delivered: [Int] = []
        let accepted1 = writer.submit(operation: {
            gate.wait()
            return Thread.isMainThread
        }, completion: { result in
            #expect((try? result.get()) == false)
            delivered.append(1)
        })
        #expect(accepted1)
        let accepted2 = writer.submit(operation: { () throws -> Int in throw TestFailure.expected }, completion: { result in
            if case .success = result { Issue.record("Expected write failure") }
            delivered.append(2)
        })
        #expect(accepted2)
        let accepted3 = writer.submit(operation: { 3 }, completion: { result in
            #expect((try? result.get()) == 3)
            delivered.append(3)
        })
        #expect(accepted3)
        #expect(writer.pendingCount == 3)
        #expect(!writer.canAccept())
        let rejected = writer.submit(operation: { 4 }, completion: { _ in Issue.record("Rejected job executed") })
        #expect(!rejected)
        gate.signal()
        await writer.drain()
        #expect(delivered == [1, 2, 3])
        #expect(writer.pendingCount == 0)
        #expect(writer.canAccept(3))
    }

    @Test func callerCancellationDoesNotDiscardAcceptedEvidence() async {
        let writer = BoundedCaptureWriter(capacity: 1)
        let gate = DispatchSemaphore(value: 0)
        var committed = false
        let caller = Task {
            let accepted = writer.submit(operation: { gate.wait(); return 42 }, completion: { result in
                committed = (try? result.get()) == 42
            })
            #expect(accepted)
        }
        await caller.value
        caller.cancel()
        let drain = Task { await writer.drain() }
        drain.cancel()
        gate.signal()
        await drain.value
        #expect(committed)
        #expect(writer.pendingCount == 0)
    }

    private enum TestFailure: Error { case expected }
}

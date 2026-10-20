import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct SubscriberOverflowTests {
    @Test func aPausedSubscriberCanReplayEveryEventAfterTheBoundedQueueFills() async throws {
        let harness = try await ServiceHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        let storage = await runtime.storage
        let cursor = try storage.checkpoint()
        let context = ServiceSessionContext(
            principalID: harness.first.principalID, deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("subscriber"), accounts: [harness.first.id]
        )
        let stream = try await runtime.subscribe(after: cursor, attachment: nil, context: context)
        for index in 0 ..< 10 {
            try await runtime.appendAndPublish(.backendError(.unknown("Burst \(index)")), live: true)
        }
        do {
            for try await _ in stream {}
            Issue.record("A full subscriber queue must request replay")
        } catch {
            #expect(error as? ServiceFailure == .resynchronizationRequired)
        }
        let replay = try storage.readEvents(after: cursor, limit: 256)
        let markers = replay.events.compactMap { event -> String? in
            if case let .backendError(.unknown(value)) = event.event,
               value.hasPrefix("Burst ") {
                value
            } else {
                nil
            }
        }
        #expect(markers == (0 ..< 10).map { "Burst \($0)" })
        #expect(await runtime.subscribers.isEmpty)
        #expect(await harness.service.activeRuntimeCount == 2)
        await harness.service.shutdown()
    }
}

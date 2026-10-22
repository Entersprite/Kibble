import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallSnapshotContinuityTests {
    @Test func skippedCallEndCannotBlockTheNextRingInTheController() async throws {
        let recipient = AudioCallRecipient(
            conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
        )
        var old = AudioCallSnapshot(id: UUID(), recipient: recipient, direction: .incoming, phase: .incoming)
        let transport = CallSnapshotTransport(call: old)
        let facade = try ServiceAudioCallService(account: .init(
            id: .init("account"), selfID: .init("self"), label: "Acme",
            connection: .connected, revision: .init("revision")
        ), client: AccountClient(transport: transport))
        let controller = AudioCallController()
        controller.start(service: facade)
        do {
            try #require(await eventually { controller.call?.id == old.id })
            old.phase = .connected
            await transport.replace(old, sequence: 2)
            try #require(await eventually { controller.call?.phase == .connected })
            // Complete snapshots can skip the ended state while delivery is interrupted.
            let next = AudioCallSnapshot(
                id: UUID(), recipient: recipient, direction: .incoming, phase: .incoming
            )
            await transport.replace(next, sequence: 5)
            try #require(await eventually { controller.call?.id == next.id })
            #expect(controller.call?.phase == .incoming)
            #expect(controller.windowRequests == 2)
            #expect(await transport.controls == 0)
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
    }
}

private actor CallSnapshotTransport: ServiceTransport {
    private let source = UUID().uuidString
    private var call: AudioCallSnapshot
    private var sequence = 1
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var controls = 0

    init(call: AudioCallSnapshot) {
        self.call = call
    }

    func negotiate(_ peer: ServiceAPIVersion) -> ServiceAPIVersion {
        peer
    }

    func replace(_ call: AudioCallSnapshot, sequence: Int) {
        self.call = call
        self.sequence = sequence
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.resume()
        }
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        guard request.operation == ReadCallState.operation else {
            controls += 1
            throw ServiceFailure.unsupportedOperation
        }
        let read = try request.decodePayload(ReadCallState.self)
        if read.after == version, read.waitMilliseconds > 0 {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    Void,
                    any Error
                >) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    waiters[id] = continuation
                }
            } onCancel: { Task { await self.cancel(id) } }
        }
        let state = ServiceCallState(version: version, isListening: true, call: call)
        // Exercise the production DTO encoding as well as the controller's event consumer.
        let response = try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(state)))
        return try ServiceCodec.decode(ServiceResponse.self, from: ServiceCodec.encode(response))
    }

    private var version: String {
        source + ":" + String(sequence)
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
@testable import ChatService

struct InterestTestClient: Sendable {
    let record: AccountRecord
    let context: ServiceSessionContext
    let transport: InProcessChatTransport
    let sequence = TestHintSequence()

    init(_ harness: ReconciliationHarness, device: String, session: String) {
        record = harness.record
        context = ServiceSessionContext(
            principalID: record.principalID, deviceID: ServiceDeviceID(device),
            sessionID: ClientSessionID(session), accounts: [record.id]
        )
        transport = InProcessChatTransport(endpoint: harness.service, context: context)
    }

    func call<P: ServiceRequestPayload>(_ payload: P) async throws -> P.Response {
        _ = try await transport.negotiate(.current)
        return try await transport.exchange(ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: record.id,
            accountRevision: record.currentRevision, deadline: Date().addingTimeInterval(5)
        ), payload: payload)).value(for: P.self)
    }

    func attach(_ generation: String = "1") async throws -> ClientAttachment {
        try await call(AttachAccountClient(generation: generation))
    }

    func hint(_ command: ChatCommand, lease: ClientAttachment, sequence: String? = nil) async throws {
        _ = try await call(SendHint(
            command: command, attachmentID: lease.id, sequence: sequence ?? self.sequence.next()
        ))
    }

    func detach(_ lease: ClientAttachment) async throws {
        _ = try await call(DetachAccountClient(attachmentID: lease.id))
    }
}

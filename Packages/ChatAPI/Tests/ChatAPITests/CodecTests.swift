import ChatAPI
import ChatKit
import Foundation
import Testing

@Suite("Service wire contract")
struct CodecTests {
    @Test
    func identifiersAndEnvelopeHaveAStableShape() throws {
        let request = try ServiceRequest(
            header: .init(requestID: ServiceRequestID("request-1")), payload: ListAccounts()
        )
        let data = try ServiceCodec.encode(request)
        let url = try #require(Bundle.module.url(
            forResource: "list-accounts",
            withExtension: "json",
            subdirectory: "Golden"
        ))
        let expected = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(String(decoding: data, as: UTF8.self) == expected)
        #expect(try ServiceCodec.decode(ServiceRequest.self, from: data) == request)
    }

    @Test
    func unknownResultRetainsNestedPayload() throws {
        let payload = JSONValue.object([
            "type": .string("futureResult"),
            "nested": .object(["optional": .array([.null, .bool(true), .string("opaque")])])
        ])
        let value = try ServiceCodec.decode(ServiceResult.self, from: payload)
        #expect(value == .unknown(type: "futureResult", payload: payload))
        #expect(try ServiceCodec.value(value) == payload)
        let response = ServiceResponse(
            requestID: ServiceRequestID("request-1"), accountID: nil, result: value
        )
        #expect(throws: ServiceFailure.unsupportedOperation) { try response.value(for: ListAccounts.self) }
    }

    @Test
    func unknownRequestSurvivesButCannotBecomeAKnownOperation() throws {
        let request = ServiceRequest(
            header: .init(requestID: ServiceRequestID("future")), operation: "futureRequiredOperation",
            payload: .object(["nested": .array([.string("kept"), .null])])
        )
        let decoded = try ServiceCodec.decode(ServiceRequest.self, from: ServiceCodec.encode(request))
        #expect(decoded == request)
        #expect(throws: ServiceFailure.unsupportedOperation) { try decoded.decodePayload(ListAccounts.self) }
    }

    @Test
    func scopeIsCheckedAtConstructionAndDispatch() throws {
        let missing = ServiceRequestHeader(requestID: ServiceRequestID("missing"))
        #expect(throws: ServiceFailure.accountRequired) {
            try ServiceRequest(header: missing, payload: LoadConversations())
        }
        let forged = ServiceRequest(header: missing, operation: "loadConversations", payload: .object([:]))
        #expect(throws: ServiceFailure.accountRequired) { try forged.decodePayload(LoadConversations.self) }
        let extra = ServiceRequestHeader(
            requestID: ServiceRequestID("extra"), accountID: ConnectedAccountID("account-a")
        )
        #expect(throws: ServiceFailure.notAuthorized) { try ServiceRequest(
            header: extra,
            payload: ListAccounts()
        ) }
    }

    @Test
    func sequenceDoesNotLoseIntegerPrecisionThroughJSON() throws {
        let cursor = ServiceCursor(
            accountID: ConnectedAccountID("account-a"), streamID: ServiceStreamID("stream-1"),
            sequence: UInt64.max
        )
        let payload = try ServiceCodec.value(cursor)
        #expect(try ServiceCodec.decode(ServiceCursor.self, from: payload) == cursor)
        guard case let .object(object) = payload else { Issue.record("Expected an object"); return }
        #expect(object["sequence"] == .string("18446744073709551615"))
    }

    @Test(arguments: ["-1", "+1", "01", "1.0", "18446744073709551616"])
    func malformedSequencesAreRefused(_ sequence: String) throws {
        let payload = JSONValue.object([
            "accountID": .string("account-a"), "streamID": .string("stream-1"), "sequence": .string(sequence)
        ])
        #expect(throws: DecodingError.self) { try ServiceCodec.decode(ServiceCursor.self, from: payload) }
    }

    @Test
    func timestampsAndDomainPayloadsKeepMicroseconds() throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse("2026-10-19T10:15:30.123456Z")
        let command = ChatCommand.markRead(conversationID: Conversation.ID("space/shared"), upTo: date)
        #expect(try ServiceCodec.decode(ChatCommand.self, from: ServiceCodec.value(command)) == command)
        let header = ServiceRequestHeader(requestID: ServiceRequestID("time"), deadline: date)
        #expect(try ServiceCodec
            .decode(ServiceRequestHeader.self, from: ServiceCodec.encode(header)) == header)
    }

    @Test
    func negotiationKeepsOptionalMinorChangesAndRejectsMajorChanges() throws {
        let supported = ServiceAPIVersion(major: 1, minor: 2)
        #expect(try supported.negotiated(with: .init(major: 1, minor: 1)) == .init(major: 1, minor: 1))
        #expect(throws: ServiceFailure.incompatibleVersion) {
            try supported.negotiated(with: .init(major: 2, minor: 0))
        }
    }

    @Test
    func missingCapabilitiesAreFalseInsideAServiceResult() throws {
        let result = ServiceResult.success(.object([:]))
        guard case let .success(value) = result else { return }
        let capabilities = try ServiceCodec.decode(Capabilities.self, from: value)
        #expect(!capabilities.canSendMessages)
        #expect(!capabilities.canSendAttachments)
    }
}

import ChatAPI
import ChatKit
import Foundation
import Testing

struct MessagePinWireTests {
    @Test func payloadsMatchTheirGoldensAndRequireAccountScope() throws {
        let read = GetMessagePins(conversationID: .init("chat"))
        let write = SetMessagePinned(
            address: MessageAddress(
                conversation: .init("chat"),
                thread: .init("thread"),
                message: .init("message")
            ),
            pinned: true, operationID: .init("pin-1")
        )
        try golden(read, named: "get-message-pins")
        try golden(write, named: "set-message-pinned")
        let header = ServiceRequestHeader(requestID: .init("request"))
        #expect(throws: ServiceFailure.accountRequired) { try ServiceRequest(header: header, payload: read) }
        #expect(throws: ServiceFailure.accountRequired) { try ServiceRequest(header: header, payload: write) }
        let request = try ServiceRequest(
            header: .init(requestID: .init("request"), accountID: .init("account")), payload: write
        )
        let decoded = try ServiceCodec.decode(ServiceRequest.self, from: ServiceCodec.encode(request))
        #expect(try decoded.decodePayload(SetMessagePinned.self) == write)
    }

    private func golden(_ value: some Encodable, named name: String) throws {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Golden"
        ))
        let expected = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(try String(decoding: ServiceCodec.encode(value), as: UTF8.self) == expected)
    }
}

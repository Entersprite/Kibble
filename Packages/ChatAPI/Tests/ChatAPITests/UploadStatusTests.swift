import ChatAPI
import Foundation
import Testing

struct UploadStatusTests {
    @Test func progressHasExplicitAccountScopeAndPreservesUnknownPhases() throws {
        let payload = GetUploadTransfer(transferID: .init("upload"))
        #expect(throws: ServiceFailure.accountRequired) {
            try ServiceRequest(header: .init(requestID: .init("request")), payload: payload)
        }
        let request = try ServiceRequest(header: .init(
            requestID: .init("request"), accountID: .init("account"), accountRevision: .init("revision")
        ), payload: payload)
        let decoded = try ServiceCodec.decode(ServiceRequest.self, from: ServiceCodec.encode(request))
        #expect(try decoded.decodePayload(GetUploadTransfer.self) == payload)
        let status = UploadTransferStatus(transfer: UploadTransfer(
            id: payload.transferID, expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            chunkSize: 65536, byteSize: 8
        ), phase: "future-provider-phase", stagedBytes: 8, providerBytesSent: 3)
        let reply = try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(status)))
        let received = try ServiceCodec.decode(ServiceResponse.self, from: ServiceCodec.encode(reply))
        #expect(try received.value(for: GetUploadTransfer.self) == status)
    }
}

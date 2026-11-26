import Foundation

extension AttachmentFetch {
    func boundedResponse(_ original: HTTPRequest, maximumBytes: Int?) async throws -> HTTPResponse {
        var request = original
        request.maxBodyBytes = maximumBytes
        if let maximumBytes, maximumBytes < 0 {
            throw HTTPBodyTooLarge(limit: maximumBytes)
        }
        let response = try await transport.send(request)
        if let maximumBytes,
           response.body.count > maximumBytes {
            throw HTTPBodyTooLarge(limit: maximumBytes)
        }
        return response
    }
}

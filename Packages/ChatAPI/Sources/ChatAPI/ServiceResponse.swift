import ChatKit
import Foundation

/// Results use explicit discriminators. A newer result remains available for
/// forwarding, but a client cannot mistake it for successful execution.
public enum ServiceResult: Codable, Hashable, Sendable {
    case success(JSONValue)
    case failure(ServiceFailure)
    case unknown(type: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "success": self = try .success(container.decode(JSONValue.self, forKey: .value))
        case "failure": self = try .failure(container.decode(ServiceFailure.self, forKey: .value))
        default: self = try .unknown(type: type, payload: JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            var object = if case let .object(fields) = payload {
                fields
            } else {
                ["value": payload]
            }
            object["type"] = .string(type)
            try JSONValue.object(object).encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .success(value):
            try container.encode("success", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .failure(failure):
            try container.encode("failure", forKey: .type)
            try container.encode(failure, forKey: .value)
        case .unknown: break
        }
    }
}

public struct ServiceResponse: Codable, Hashable, Sendable {
    public let version: ServiceAPIVersion
    public let requestID: ServiceRequestID
    public let accountID: ConnectedAccountID?
    public let result: ServiceResult

    public init(
        requestID: ServiceRequestID, accountID: ConnectedAccountID?, result: ServiceResult,
        version: ServiceAPIVersion = .current
    ) {
        self.version = version
        self.requestID = requestID
        self.accountID = accountID
        self.result = result
    }

    public init(replyingTo request: ServiceRequest, result: ServiceResult) {
        self.init(
            requestID: request.header.requestID, accountID: request.header.accountID,
            result: result, version: request.header.version
        )
    }

    public func value<Payload: ServiceRequestPayload>(for _: Payload.Type) throws -> Payload.Response {
        switch result {
        case let .success(value): try ServiceCodec.decode(Payload.Response.self, from: value)
        case let .failure(failure): throw failure
        case .unknown: throw ServiceFailure.unsupportedOperation
        }
    }
}

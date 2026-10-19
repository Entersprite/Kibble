import ChatKit
import Foundation

/// A lookup key, never authority to fetch arbitrary client-supplied metadata.
public enum MediaSelector: Codable, Hashable, Sendable {
    case attachment(String)
    case customEmoji(String)
    case remoteImage(URL)
    case unknown(type: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey { case type, id, url }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        switch type {
        case "attachment": self = try .attachment(values.decode(String.self, forKey: .id))
        case "customEmoji": self = try .customEmoji(values.decode(String.self, forKey: .id))
        case "remoteImage": self = try .remoteImage(values.decode(URL.self, forKey: .url).absoluteURL)
        default: self = try .unknown(type: type, payload: JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            var fields: [String: JSONValue] = if case let .object(object) = payload {
                object
            } else {
                ["value": payload]
            }
            fields["type"] = .string(type)
            try JSONValue.object(fields).encode(to: encoder)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .attachment(id):
            try values.encode("attachment", forKey: .type)
            try values.encode(id, forKey: .id)
        case let .customEmoji(id):
            try values.encode("customEmoji", forKey: .type)
            try values.encode(id, forKey: .id)
        case let .remoteImage(url):
            try values.encode("remoteImage", forKey: .type)
            try values.encode(url.absoluteURL, forKey: .url)
        case .unknown: break
        }
    }
}

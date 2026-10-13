import Foundation

/// Only fixed labels and bounded status numbers survive an RPC refusal.
/// Messages, detail metadata, cookies and URLs are never retained.
public struct MeetCallRefusal: Sendable, Equatable {
    public enum MessageKind: String, Sendable {
        case absent, unclassified, classified, oversized, malformed
    }

    /// These are vocabulary matches, not a claim that a field was rejected.
    public enum MessageTopic: String, Sendable {
        case missing = "missing requirements"
        case unsupported
        case parsing = "request parsing"
        case dtls = "DTLS/SRTP"
        case ice = "ICE/STUN"
        case codecs
        case extensions = "RTP extensions"
        case configuration
        case audio, video, transport, channels
    }

    public enum BodyKind: String, Sendable {
        case empty, json, protobuf, other
    }

    public enum Status: String, Sendable {
        case unauthenticated = "UNAUTHENTICATED"
        case permissionDenied = "PERMISSION_DENIED"
        case invalidArgument = "INVALID_ARGUMENT"
        case failedPrecondition = "FAILED_PRECONDITION"
        case resourceExhausted = "RESOURCE_EXHAUSTED"
        case unavailable = "UNAVAILABLE"
        case internalError = "INTERNAL"
    }

    public enum Reason: String, Sendable {
        case credentialsMissing = "CREDENTIALS_MISSING"
        case apiKeyInvalid = "API_KEY_INVALID"
        case apiKeyExpired = "API_KEY_EXPIRED"
        case apiKeyServiceBlocked = "API_KEY_SERVICE_BLOCKED"
        case apiKeyReferrerBlocked = "API_KEY_HTTP_REFERRER_BLOCKED"
        case apiKeyIPBlocked = "API_KEY_IP_ADDRESS_BLOCKED"
        case apiDisabled = "API_DISABLED"
        case serviceDisabled = "SERVICE_DISABLED"
        case insufficientScope = "ACCESS_TOKEN_SCOPE_INSUFFICIENT"
    }

    /// Fixed categories only; neither arbitrary field paths nor the server's
    /// violation descriptions are retained in a report.
    public enum InvalidField: String, Sendable {
        case media = "media config"
        case dtls = "DTLS config"
        case ice = "ICE config"
        case codecs
        case extensions = "RTP extensions"
    }

    public let bodyKind: BodyKind
    public let code: Int?
    public let status: Status?
    public let reason: Reason?
    public let invalidFields: [InvalidField]
    public let messageKind: MessageKind
    public let messageTopics: [MessageTopic]

    public init(body: Data) {
        if body.isEmpty {
            self.init(kind: .empty)
        } else if let fields = Self.jsonFields(body) {
            self.init(kind: .json, fields: fields)
        } else if let fields = Self.protobufFields(body) {
            self.init(kind: .protobuf, fields: fields)
        } else {
            self.init(kind: .other)
        }
    }

    public var safeDescription: String {
        var parts = ["error body \(bodyKind.rawValue)"]
        if let code {
            parts.append("code \(code)")
        }
        if let status {
            parts.append(status.rawValue)
        }
        if let reason {
            parts.append(reason.rawValue)
        }
        if !invalidFields.isEmpty {
            parts.append("rejected: " + invalidFields.map(\.rawValue).joined(separator: ", "))
        }
        if !messageTopics.isEmpty {
            parts.append("message topics: " + messageTopics.map(\.rawValue).joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    private struct Fields {
        let code: Int?
        let status: Status?
        let reason: Reason?
        var invalidFields: [InvalidField] = []
        var message: MessageSummary = .init(kind: .absent, topics: [])
    }

    private struct MessageSummary {
        let kind: MessageKind
        let topics: [MessageTopic]
    }

    private init(kind: BodyKind, fields: Fields? = nil) {
        bodyKind = kind
        code = fields?.code
        status = fields?.status
        reason = fields?.reason
        invalidFields = fields?.invalidFields ?? []
        messageKind = fields?.message.kind ?? .absent
        messageTopics = fields?.message.topics ?? []
    }

    private static func jsonFields(_ body: Data) -> Fields? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        let code = (error["code"] as? Int).flatMap { (0 ... 599).contains($0) ? $0 : nil }
        let status = (error["status"] as? String).flatMap(Status.init(rawValue:))
        let details = error["details"] as? [[String: Any]] ?? []
        let reason = details.lazy.compactMap { detail -> Reason? in
            guard detail["@type"] as? String == "type.googleapis.com/google.rpc.ErrorInfo",
                  let name = detail["reason"] as? String else { return nil }
            return Reason(rawValue: name)
        }.first
        let invalid = details.filter {
            $0["@type"] as? String == "type.googleapis.com/google.rpc.BadRequest"
        }.flatMap { $0["fieldViolations"] as? [[String: Any]] ?? [] }
            .compactMap { ($0["field"] as? String).flatMap(invalidField) }
        return Fields(
            code: code, status: status, reason: reason, invalidFields: unique(invalid),
            message: summarizeMessage(error["message"] as? String)
        )
    }

    /// google.rpc.Status: code 1, message 2, repeated Any details 3.
    private static func protobufFields(_ body: Data) -> Fields? {
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = text.flatMap { Data(base64Encoded: $0) } ?? body
        let scan = ProtoFieldScan.fields(in: bytes)
        let codes = ProtoFieldScan.varintValues(ofField: 1, in: bytes)
        guard !scan.truncated, codes.count == 1, (1 ... 16).contains(codes[0]),
              scan.fields.allSatisfy({ field in
                  (field.number == 1 && field.wireType == 0)
                      || ((field.number == 2 || field.number == 3) && field.wireType == 2)
              })
        else { return nil }
        let reason = ProtoFieldScan.payloads(ofField: 3, in: bytes).lazy.compactMap(errorInfoReason).first
        let invalid = ProtoFieldScan.payloads(ofField: 3, in: bytes).flatMap(badRequestFields)
        let messages = ProtoFieldScan.payloads(ofField: 2, in: bytes)
        let message: MessageSummary = if messages.isEmpty {
            .init(kind: .absent, topics: [])
        } else if messages.count == 1, let text = String(data: messages[0], encoding: .utf8) {
            summarizeMessage(text)
        } else {
            .init(kind: .malformed, topics: [])
        }
        return Fields(
            code: Int(codes[0]), status: nil, reason: reason, invalidFields: unique(invalid), message: message
        )
    }

    /// Discard the message after matching a bounded vocabulary. No text from
    /// the server, even a quoted field/value or a URL, survives this function.
    private static func summarizeMessage(_ message: String?) -> MessageSummary {
        guard let message, !message.isEmpty else { return .init(kind: .absent, topics: []) }
        guard message.utf8.count <= 8192 else { return .init(kind: .oversized, topics: []) }
        let words = Set(message.lowercased().split { !$0.isLetter }.map(String.init))
        let vocabulary: [(MessageTopic, Set<String>)] = [
            (.missing, ["missing", "required", "requires", "require", "empty"]),
            (.unsupported, ["unsupported", "unimplemented"]),
            (.parsing, ["parse", "parsing", "deserialize", "deserialization", "malformed", "protobuf"]),
            (.dtls, ["dtls", "dtlsconfig", "srtp", "cipher", "fingerprint", "cryptosuite"]),
            (.ice, ["ice", "iceconfig", "stun", "stunconfig", "ufrag", "candidate", "candidates"]),
            (.codecs, ["codec", "codecs", "opus", "red", "packetization"]),
            (.extensions, ["extension", "extensions", "rtpheaderextensions"]),
            (.configuration, ["config", "configuration", "clientconfig", "serverconfig"]),
            (.audio, ["audio"]), (.video, ["video"]), (.transport, ["transport"]),
            (.channels, ["channel", "channels", "datachannel", "datachannels", "collections"])
        ]
        let topics = vocabulary.compactMap { topic, knownWords in
            words.isDisjoint(with: knownWords) ? nil : topic
        }
        return .init(kind: topics.isEmpty ? .unclassified : .classified, topics: topics)
    }

    private static func errorInfoReason(_ detail: Data) -> Reason? {
        let types = ProtoFieldScan.payloads(ofField: 1, in: detail)
        let values = ProtoFieldScan.payloads(ofField: 2, in: detail)
        guard types.count == 1, values.count == 1,
              String(data: types[0], encoding: .utf8) == "type.googleapis.com/google.rpc.ErrorInfo"
        else { return nil }
        let names = ProtoFieldScan.payloads(ofField: 1, in: values[0])
        guard names.count == 1, let name = String(data: names[0], encoding: .utf8) else { return nil }
        return Reason(rawValue: name)
    }

    /// google.rpc.BadRequest has repeated field_violations in 1. Each violation
    /// has field path 1, description 2; read only a bounded, recognized path.
    private static func badRequestFields(_ detail: Data) -> [InvalidField] {
        guard (try? MeetProto.text(1, detail)) == "type.googleapis.com/google.rpc.BadRequest",
              let request = try? MeetProto.payload(2, detail),
              !ProtoFieldScan.fields(in: request).truncated else { return [] }
        return ProtoFieldScan.payloads(ofField: 1, in: request).compactMap { violation in
            (try? MeetProto.text(1, violation)).flatMap(invalidField)
        }
    }

    private static func invalidField(_ field: String) -> InvalidField? {
        guard field.utf8.count <= 512 else { return nil }
        var path = field.lowercased().replacingOccurrences(of: "_", with: "")
        if path.hasPrefix("mediasession.") {
            path.removeFirst("mediasession.".count)
        }
        guard path == "clientconfig" || path.hasPrefix("clientconfig.") else { return nil }
        for (prefix, category) in [
            ("clientconfig.dtlsconfig", InvalidField.dtls),
            ("clientconfig.stunconfig", .ice),
            ("clientconfig.iceconfig", .ice),
            ("clientconfig.codecs", .codecs),
            ("clientconfig.rtpheaderextensions", .extensions)
        ] where path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[") {
            return category
        }
        return path == "clientconfig" ? .media : nil
    }

    private static func unique(_ fields: [InvalidField]) -> [InvalidField] {
        fields.reduce(into: []) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
    }
}

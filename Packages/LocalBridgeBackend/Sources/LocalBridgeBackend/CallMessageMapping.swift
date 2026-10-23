import ChatKit
import Foundation
import GChatBridgeCore

enum CallMessageMapping {
    static func status(in annotations: [Annotation]) -> MessageCallStatus? {
        guard let call = call(in: annotations) else { return nil }
        return switch call.callStatus {
        case 1: .started
        case 2: .missed
        case 3: .ended
        case let raw: .unknown(String(raw))
        }
    }

    static func metadata(in annotations: [Annotation]) -> MessageCallMetadata? {
        guard let call = call(in: annotations) else { return nil }
        let meet = call.callMetadata.meetMetadata
        let reference = validReference(meet.meetingCode) ? meet.meetingCode : nil
        let value = MessageCallMetadata(
            reference: reference,
            joinURL: joinURL(meet.meetingURL, reference: reference),
            endedAt: call.hasCallEndedTimestamp ? date(call.callEndedTimestamp) : nil,
            participantsChangedAt: call.hasParticipantListRevisionTimestamp
                ? date(call.participantListRevisionTimestamp) : nil
        )
        return value.isEmpty ? nil : value
    }

    private static func call(in annotations: [Annotation]) -> CallAnnotationData? {
        annotations.compactMap { annotation in
            guard annotation.type == .gsuiteIntegration,
                  case let .gsuiteIntegrationMetadata(integration)? = annotation.metadata,
                  integration.clientType == 1, integration.hasCallData else { return nil }
            return integration.callData
        }.first
    }

    static func validReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    static func joinURL(_ value: String, reference: String?) -> URL? {
        guard value.utf8.count <= 512, let url = URL(string: value),
              url.scheme == "https", url.host == "meet.google.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), validReference(String(url.path.dropFirst())),
              url.absoluteString == "https://meet.google.com" + url.path,
              reference.map({ url.path == "/" + $0 }) ?? true
        else { return nil }
        return url
    }

    static func date(_ value: ComGoogleProtobufTimestamp) -> Date? {
        guard value.hasSeconds, (0 ... 253_402_300_799).contains(value.seconds),
              (0 ... 999_999_999).contains(value.nanos) else { return nil }
        return Date(timeIntervalSince1970: Double(value.seconds) + Double(value.nanos) / 1e9)
    }
}

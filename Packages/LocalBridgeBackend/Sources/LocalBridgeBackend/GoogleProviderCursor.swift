import ChatKit
import Foundation
import GChatBridgeCore

struct GoogleProviderCursor: Codable, Sendable {
    var version = 1
    var identity: String?
    var baseline = false
    var user: Int64 = 0
    var groups: [String: Int64] = [:]

    init() {}

    init(data: Data?) {
        guard let data, data.count <= 512 * 1024,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.groups.count <= 4096 else { self.init(); return }
        self = value
    }

    mutating func apply(_ patch: ProviderCursorPatch) {
        if patch.rebase {
            groups = [:]; user = 0
        }
        if let identity = patch.identity {
            self.identity = identity
        }
        if let baseline = patch.baseline {
            self.baseline = baseline
        }
        if let user = patch.user {
            self.user = max(self.user, user)
        }
        for (id, revision) in patch.groups {
            groups[id] = max(groups[id] ?? 0, revision)
        }
    }

    func encoded() throws -> Data {
        guard groups.count <= 4096
        else { throw ChatError.decoding("Provider recovery capacity was exceeded.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 512 * 1024
        else { throw ChatError.decoding("Provider recovery capacity was exceeded.") }
        return data
    }
}

struct ProviderCursorPatch: Sendable {
    var identity: String?
    var baseline: Bool?
    var user: Int64?
    var groups: [String: Int64] = [:]
    var rebase = false
}

extension ChannelEventMapping {
    static func recoveryEvents(_ event: Event) throws -> [ChatEvent] {
        var mapped = try chatEvents(from: ChannelEvent(protobuf: event))
        if !event.unknownFields.data.isEmpty || event.bodies
            .contains(where: { !$0.unknownFields.data.isEmpty }) ||
            !event.body.unknownFields.data.isEmpty {
            let bytes = try event.serializedData()
            mapped.append(.unknown(type: "googlechat.recovery.unmapped", payload: .object([
                "type": .string("googlechat.recovery.unmapped"),
                "protobuf": .string(bytes.base64EncodedString())
            ])))
        }
        return mapped
    }
}

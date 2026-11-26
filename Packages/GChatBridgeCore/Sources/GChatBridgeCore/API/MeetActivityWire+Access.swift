import Foundation

public extension MeetActivityWire {
    enum AccessPreset: String, CaseIterable, Sendable {
        case open, trusted, restricted

        fileprivate var wireValue: UInt64 {
            switch self {
            case .open: 1
            case .trusted: 2
            case .restricted: 3
            }
        }

        fileprivate init?(wireValue: UInt64) {
            guard let preset = Self.allCases.first(where: { $0.wireValue == wireValue }) else { return nil }
            self = preset
        }
    }

    static func meetingAccessPreset(in space: Data, saved: Bool = false) -> AccessPreset? {
        guard let settings = spaceSettings(in: space, saved: saved),
              let value = try? MeetProto.value(saved ? 11 : 12, settings) else { return nil }
        return AccessPreset(wireValue: value)
    }

    static func joinRequestsAllowed(in space: Data, saved: Bool = false) -> Bool? {
        guard let settings = spaceSettings(in: space, saved: saved),
              let value = try? MeetProto.value(saved ? 38 : 40, settings), value == 1 || value == 2
        else { return nil }
        if !saved {
            let preset = meetingAccessPreset(in: space)
            guard preset == .trusted || preset == .restricted, usesRegularMeetingScaling(settings)
            else { return nil }
        }
        return value == 2
    }

    private static func usesRegularMeetingScaling(_ settings: Data) -> Bool {
        guard ProtoFieldScan.fields(in: settings).fields.contains(where: { $0.number == 49 })
        else { return true }
        guard let scaling = try? MeetProto.value(49, settings) else { return false }
        return scaling <= 1
    }

    static func availableMeetingAccessPresets(in space: Data) -> [AccessPreset] {
        guard let info = try? MeetProto.payload(6, space) else { return [] }
        let fields = ProtoFieldScan.fields(in: info)
        guard !fields.truncated else { return [] }
        let entries = fields.fields.filter { $0.number == 51 }
        if !entries.isEmpty {
            guard entries.count <= 32, entries.allSatisfy({ $0.wireType == 2 })
            else { return [] }
            return structuredAccessPresets(in: info)
        }
        let legacy = fields.fields.filter { $0.number == 27 }
        guard legacy.count <= 32, legacy.allSatisfy({ $0.wireType == 0 || $0.wireType == 2 })
        else { return [] }
        var values = ProtoFieldScan.varintValues(ofField: 27, in: info)
        for packed in ProtoFieldScan.payloads(ofField: 27, in: info) {
            guard let decoded = ProtoFieldScan.packedVarintValues(in: packed, limit: 32 - values.count)
            else { return [] }
            values.append(contentsOf: decoded)
        }
        return AccessPreset.allCases.filter { values.contains($0.wireValue) }
    }

    private static func structuredAccessPresets(in info: Data) -> [AccessPreset] {
        var states: [UInt64: UInt64] = [:]
        for row in ProtoFieldScan.payloads(ofField: 51, in: info) {
            guard let preset = try? MeetProto.value(1, row), let state = try? MeetProto.value(2, row),
                  states.updateValue(state, forKey: preset) == nil else { return [] }
        }
        return AccessPreset.allCases.filter { states[$0.wireValue] == 1 }
    }

    static func meetingAccessPreset(
        _ preset: AccessPreset,
        space: String,
        requestID: UUID
    ) throws -> Request {
        try updateSpace(
            space, callInfo: MeetProto.bytes(11, MeetProto.number(12, preset.wireValue)),
            mask: ["call_info.settings.access_type", "settings.access_type"],
            requestID: requestID, savedSettings: MeetProto.number(11, preset.wireValue)
        )
    }
}

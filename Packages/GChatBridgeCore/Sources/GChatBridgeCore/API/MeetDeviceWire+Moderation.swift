import Foundation

extension MeetDeviceWire {
    private static let muteMask = MeetProto.string(1, "audio_mute_request.by_meeting_device_id")
    private static let joinStateMask = MeetProto.string(1, "join_state")

    static func hasDeviceEnum(_ value: UInt64, field: Int, in device: Data, fields: [ProtoField]) -> Bool {
        let entries = fields.filter { $0.number == field }
        guard entries.count <= 256, entries.allSatisfy({ $0.wireType == 0 || $0.wireType == 2 })
        else { return false }
        var values = ProtoFieldScan.varintValues(ofField: field, in: device)
        for packed in ProtoFieldScan.payloads(ofField: field, in: device) {
            guard let decoded = ProtoFieldScan.packedVarintValues(in: packed, limit: 256 - values.count)
            else { return false }
            values.append(contentsOf: decoded)
        }
        return values.contains(value)
    }

    static func removeParticipant(device: String) -> Data {
        updateJoinState(device: device, state: 7)
    }

    static func sendToWaitingRoom(device: String) -> Data {
        let target = MeetProto.string(1, device) + MeetProto.number(4, 7) + MeetProto.number(28, 9)
        let mask = joinStateMask + MeetProto.string(1, "final_state_reason")
        return MeetProto.bytes(1, target) + MeetProto.bytes(2, mask)
    }

    static func blockUser(device: String) -> Data {
        MeetProto.string(1, device)
    }

    static func pinnedForEveryone(in device: Data) -> Bool? {
        guard MeetActivityCollections.has(52, device) else { return false }
        guard let spotlight = try? MeetProto.payload(52, device),
              !ProtoFieldScan.fields(in: spotlight).truncated else { return nil }
        guard MeetActivityCollections.has(1, spotlight) else { return false }
        guard let state = try? MeetProto.value(1, spotlight), state <= 1 else { return nil }
        return state == 1
    }

    static func setPinForEveryone(device: String, pinned: Bool) -> Data {
        var value = MeetProto.string(1, device)
        if pinned {
            value += MeetProto.bytes(52, MeetProto.number(1, 1))
        }
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, MeetProto.string(1, "spotlight_info"))
    }

    static func moderationUserID(in device: Data) -> String? {
        let profile = try? MeetProto.payload(55, device)
        let current = profile.flatMap { try? MeetProto.text(2, $0) }
        let legacy = try? MeetProto.text(49, device)
        return [current, legacy].compactMap { value in
            guard let value, !value.isEmpty, value.utf8.count <= 32,
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
            let digits = value.drop(while: { $0 == "0" })
            return digits.isEmpty ? nil : String(digits)
        }.first
    }

    static func updateJoinState(device: String, state: UInt64) -> Data {
        let target = MeetProto.string(1, device) + MeetProto.number(4, state)
        return MeetProto.bytes(1, target) + MeetProto.bytes(2, joinStateMask)
    }

    static func bulkJoinState(space: String, targets: [String], state: UInt64) -> Data {
        bulkUpdate(space: space, targets: targets, value: MeetProto.number(4, state), mask: joinStateMask)
    }

    static func audioMuteRequester(in payload: Data, space: String) -> String? {
        guard let request = try? MeetProto.payload(12, payload),
              let name = try? MeetProto.text(1, request), validDevice(name),
              name.hasPrefix(space + "/devices/") else { return nil }
        return name
    }

    static func audioMute(device: String, requester: String?) -> Data {
        let value = MeetProto.string(1, device) + audioMuteUpdate(requester)
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, muteMask)
    }

    static func bulkAudioMute(space: String, targets: [String], requester: String) -> Data {
        bulkUpdate(space: space, targets: targets, value: audioMuteUpdate(requester), mask: muteMask)
    }

    private static func bulkUpdate(space: String, targets: [String], value: Data, mask: Data) -> Data {
        let addressed = targets.reduce(into: MeetProto.string(1, space)) { $0 += MeetProto.string(2, $1) }
        return addressed + MeetProto.bytes(3, value) + MeetProto.bytes(4, mask)
    }

    private static func audioMuteUpdate(_ requester: String?) -> Data {
        MeetProto.bytes(12, requester.map { MeetProto.string(1, $0) } ?? Data())
    }

    static func confirmedBulkUpdates(
        _ body: Data, space: String, targets: Set<String>, matches: (Device) -> Bool
    ) throws -> Int {
        let data = try MeetProto.decode(body)
        let entries = ProtoFieldScan.payloads(ofField: 1, in: data)
        guard entries.count <= targets.count,
              entries.count == ProtoFieldScan.fields(in: data).fields.filter({ $0.number == 1 }).count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        var seen: Set<String> = []
        var accepted = 0
        for entry in entries {
            let variants = ProtoFieldScan.fields(in: entry).fields.filter { $0.number == 2 || $0.number == 3 }
            guard variants.count == 1, let variant = variants.first else {
                throw MeetCallWire.WireError.malformedResponse
            }
            let name: String
            if variant.number == 3 {
                let device = try devicePayload(MeetProto.payload(3, entry), in: space)
                name = device.name
                guard matches(device) else {
                    throw MeetCallWire.WireError.malformedResponse
                }
                if ProtoFieldScan.fields(in: entry).fields.contains(where: { $0.number == 1 }),
                   try MeetProto.text(1, entry) != name {
                    throw MeetCallWire.WireError.malformedResponse
                }
                accepted += 1
            } else {
                try MeetProto.validate(MeetProto.payload(2, entry))
                name = try MeetProto.text(1, entry)
            }
            guard targets.contains(name), seen.insert(name).inserted else {
                throw MeetCallWire.WireError.malformedResponse
            }
        }
        return accepted
    }
}

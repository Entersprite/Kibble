import Foundation

public extension MeetDeviceSession {
    func setHandRaised(_ raised: Bool, currentName: String?) async throws -> String? {
        try begin()
        defer { busy = false }
        guard mediaConnected, let device,
              device.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        if raised {
            if let currentName {
                return currentName
            }
            let response = try await send(
                "MeetingHandRaiseService/CreateHandRaise",
                body: MeetProto.string(1, space.name) + MeetProto.bytes(2, Data())
            )
            let resource = try MeetProto.decode(response.body)
            let name = try MeetProto.text(1, resource)
            guard name.hasPrefix(space.name + "/"), name.utf8.count <= 512 else {
                throw MeetCallWire.WireError.malformedResponse
            }
            return name
        }
        guard let currentName else { return nil }
        try await deleteHand(currentName)
        return nil
    }

    func lowerHand(_ name: String) async throws {
        try begin()
        defer { busy = false }
        guard mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        try await deleteHand(name)
    }

    func clearHands() async throws {
        try begin()
        defer { busy = false }
        guard mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        _ = try await send("MeetingHandRaiseService/ClearHandRaises", body: MeetProto.string(1, space.name))
    }

    private func deleteHand(_ name: String) async throws {
        guard name.hasPrefix(space.name + "/"), name.utf8.count <= 512 else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        _ = try await send("MeetingHandRaiseService/DeleteHandRaise", body: MeetProto.string(1, name))
    }
}

import Foundation

public extension MeetDeviceSession {
    func respondToWaitingParticipants(_ targets: [String], admit: Bool, bulk: Bool) async throws -> Int {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        guard !targets.isEmpty, targets.count <= 256, bulk || targets.count == 1,
              Set(targets).count == targets.count, targets.allSatisfy({ name in
                  name != device.name && MeetDeviceWire.validDevice(name)
                      && name.hasPrefix(space.name + "/devices/")
              }) else { throw MeetCallWire.WireError.invalidIdentifier }
        let state: UInt64 = admit ? 1 : 4
        if bulk {
            let body = MeetDeviceWire.bulkJoinState(space: space.name, targets: targets, state: state)
            let reply = try await send(
                "MeetingDeviceService/BulkUpdateMeetingDevices",
                body: body,
                isDevice: true
            )
            try Task.checkCancellation()
            guard !closed else { throw MeetDeviceSessionError.closed }
            return try MeetDeviceWire.confirmedBulkUpdates(
                reply.body,
                space: space.name,
                targets: Set(targets)
            ) {
                $0.joinState == state && (!admit || !$0.isDeleted)
            }
        }
        let target = targets[0]
        let body = MeetDeviceWire.updateJoinState(device: target, state: state)
        let reply = try await send("MeetingDeviceService/UpdateMeetingDevice", body: body, isDevice: true)
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let confirmed = try MeetDeviceWire.device(from: reply.body, in: space.name)
        guard confirmed.name == target, confirmed.joinState == state, !admit || !confirmed.isDeleted else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return 1
    }
}

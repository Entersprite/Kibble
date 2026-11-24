import Foundation

public extension MeetDeviceSession {
    func setPinForEveryone(_ target: String, pinned: Bool) async throws {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        guard MeetDeviceWire.validDevice(target), target.hasPrefix(space.name + "/devices/") else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let reply = try await send(
            "MeetingDeviceService/UpdateMeetingDevice",
            body: MeetDeviceWire.setPinForEveryone(device: target, pinned: pinned), isDevice: true
        )
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let receipt = try MeetDeviceWire.device(from: reply.body, in: space.name)
        guard receipt.name == target else { throw MeetCallWire.WireError.malformedResponse }
    }

    func removeParticipant(_ target: String) async throws {
        try await ejectParticipant(target, toWaitingRoom: false)
    }

    func sendParticipantToWaitingRoom(_ target: String) async throws {
        try await ejectParticipant(target, toWaitingRoom: true)
    }

    /// A valid reply without the addressed terminal device still needs a roster read.
    func blockParticipant(_ target: String) async throws -> Bool {
        try begin()
        defer { busy = false }
        let local = try validateModerationTarget(target)
        let response = try await send(
            "MeetingDeviceService/BlockUser", body: MeetDeviceWire.blockUser(device: target), isDevice: true
        )
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let affected = try MeetDeviceWire.affectedDevices(from: response.body, in: space.name)
        guard !affected.contains(where: { $0.name == local })
        else { throw MeetCallWire.WireError.malformedResponse }
        guard let exact = affected.first(where: { $0.name == target }) else { return false }
        return exact.isDeleted || exact.joinState == 7
    }

    private func ejectParticipant(_ target: String, toWaitingRoom: Bool) async throws {
        try begin()
        defer { busy = false }
        _ = try validateModerationTarget(target)
        let response = try await send(
            "MeetingDeviceService/UpdateMeetingDevice",
            body: toWaitingRoom ? MeetDeviceWire.sendToWaitingRoom(device: target)
                : MeetDeviceWire.removeParticipant(device: target),
            isDevice: true
        )
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let receipt = try MeetDeviceWire.device(from: response.body, in: space.name)
        guard receipt.name == target,
              toWaitingRoom ? receipt.wasSentToWaitingRoom : receipt.wasRemoved
        else { throw MeetCallWire.WireError.malformedResponse }
    }

    private func validateModerationTarget(_ target: String) throws -> String {
        guard !closed, mediaConnected, let device, device.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        guard target != device.name, MeetDeviceWire.validDevice(target),
              target.hasPrefix(space.name + "/devices/")
        else { throw MeetCallWire.WireError.invalidIdentifier }
        return device.name
    }

    func muteParticipants(_ targets: [String], bulk: Bool) async throws -> Int {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        guard !targets.isEmpty, targets.count <= 256, bulk || targets.count == 1,
              Set(targets).count == targets.count, targets.allSatisfy({ target in
                  target != device.name && MeetDeviceWire.validDevice(target)
                      && target.hasPrefix(space.name + "/devices/")
              }) else { throw MeetCallWire.WireError.invalidIdentifier }
        if bulk {
            let body = MeetDeviceWire.bulkAudioMute(
                space: space.name,
                targets: targets,
                requester: device.name
            )
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
                $0.audioMuteRequester.map { $0 == device.name } ?? true
            }
        }
        let target = targets[0]
        let body = MeetDeviceWire.audioMute(device: target, requester: device.name)
        let reply = try await send("MeetingDeviceService/UpdateMeetingDevice", body: body, isDevice: true)
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let received = try MeetDeviceWire.device(from: reply.body, in: space.name)
        guard received.name == target,
              received.audioMuteRequester.map({ $0 == device.name }) ?? true else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return 1
    }

    func acknowledgeRemoteMute() async throws {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        let body = MeetDeviceWire.audioMute(device: device.name, requester: nil)
        let reply = try await send(
            "MeetingDeviceService/UpdateMeetingDevice", body: body, isDevice: true, timeout: .seconds(5)
        )
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        let received = try MeetDeviceWire.device(from: reply.body, in: space.name)
        guard received.name == device.name, received.audioMuteRequester == nil else {
            throw MeetCallWire.WireError.malformedResponse
        }
    }
}

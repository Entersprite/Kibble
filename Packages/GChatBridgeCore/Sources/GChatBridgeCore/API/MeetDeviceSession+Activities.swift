import Foundation

public extension MeetDeviceSession {
    func agendaArtifacts() async throws -> [MeetAgendaArtifact]? {
        try await agendaFiles()?.artifacts
    }

    func agendaFiles() async throws -> MeetAgendaFiles? {
        try await registeredAgenda(joinState: 1).map {
            MeetAgendaFiles(
                artifacts: MeetAgendaWire.artifacts($0),
                attachments: MeetAgendaWire.attachments($0),
                guests: MeetAgendaGuestWire.guests($0)
            )
        }
    }

    func waitingAgendaAttachments() async throws -> [MeetAgendaFiles.Attachment] {
        guard device?.isPresentation == false else { throw MeetDeviceSessionError.notJoined }
        return try await registeredAgenda(joinState: 13).map(MeetAgendaWire.attachments) ?? []
    }

    private func registeredAgenda(joinState: UInt64) async throws -> Data? {
        guard !closed, mediaConnected, let current = device, current.joinState == joinState,
              !current.isDeleted
        else { throw MeetDeviceSessionError.notJoined }
        // This optional read does not take the device mutation slot.
        let response = try await send(MeetAgendaWire.method, body: Data(), timeout: .seconds(5))
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        guard mediaConnected, device?.name == current.name, device?.joinState == joinState,
              device?.isDeleted == false
        else { throw MeetDeviceSessionError.notJoined }
        return try MeetAgendaWire.event(
            response.body,
            matching: space.url,
            requireConferenceLink: joinState == 13
        )
    }

    func performActivity(
        _ request: MeetActivityWire.Request, observed: MeetActivityCollections.Snapshot? = nil
    ) async throws -> Data {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        try request.validateScope(space.name, observed: observed)
        let response = try await send(request.method, body: request.body)
        return try MeetProto.decode(response.body)
    }

    func activityCollections(
        refreshHostAccess: Bool = false,
        isolatingOptionalFailures: Bool = false,
        timeout: Duration? = nil
    ) async throws -> MeetActivityCollections.Snapshot {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1
        else { throw MeetDeviceSessionError.notJoined }
        var body = MeetActivityCollections.sync(space: space.name)
        if refreshHostAccess {
            body += MeetProto.bytes(3, Data())
        }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: body,
            timeout: timeout
        )
        var snapshot = try isolatingOptionalFailures
            ? MeetActivityCollections.availableSnapshot(response.body, space: space.name)
            : MeetActivityCollections.decode(response.body, space: space.name)
        if refreshHostAccess {
            let data = try MeetProto.decode(response.body)
            snapshot.devices = try MeetCallCollectionsWire.devices(in: data, space: space.name)
            snapshot.hostAccess = snapshot.devices?.hostAccess(for: device.name)
        }
        return snapshot
    }

    enum JoinedActivityCollection: UInt64, Sendable {
        case space = 2, messages = 4
    }

    func joinedActivityCollections(
        including collection: JoinedActivityCollection, timeout: Duration = .seconds(8)
    ) async throws
        -> MeetActivityCollections.Snapshot {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1, !device.isDeleted,
              !device.isPresentation else { throw MeetDeviceSessionError.notJoined }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: MeetProto.string(1, space.name) + MeetProto.bytes(3, Data())
                + MeetProto.bytes(collection.rawValue, Data()),
            timeout: timeout
        )
        try Task.checkCancellation()
        guard !closed, self.device?.name == device.name else { throw MeetDeviceSessionError.closed }
        let data = try MeetProto.decode(response.body)
        var snapshot = try MeetActivityCollections.availableSnapshot(response.body, space: space.name)
        snapshot.devices = try MeetCallCollectionsWire.devices(in: data, space: space.name)
        snapshot.hostAccess = snapshot.devices?.hostAccess(for: device.name)
        return snapshot
    }

    func changeParticipantRole(_ name: String, cohost: Bool) async throws {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, let device, device.joinState == 1
        else { throw MeetDeviceSessionError.notJoined }
        guard name != device.name, name.hasPrefix(space.name + "/devices/") else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let body = try MeetDeviceWire.changeRole(device: name, cohost: cohost)
        let reply = try await send("MeetingDeviceService/ChangeMeetingRole", body: body, isDevice: true)
        try Task.checkCancellation()
        guard !closed else { throw MeetDeviceSessionError.closed }
        try MeetDeviceWire.confirmRoleChange(reply.body, space: space.name, target: name, cohost: cohost)
    }

    func activityPolicyDenials() async throws -> Set<String> {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        let user = try await send("MeetingUserService/GetUser", body: MeetProto.string(1, "users/me"))
        let data = try MeetProto.decode(user.body)
        var denied: Set<String> = []
        if MeetActivityCollections.number(48, data) == 2 {
            denied.insert("transcription")
        }
        let notes = try await send(
            "MeetingUserService/GetSmartNotesEligibilities",
            body: MeetProto.string(1, "users/me")
        )
        let eligibility = try MeetProto.decode(notes.body)
        if MeetActivityCollections.number(1, eligibility) != 2 {
            denied.insert("notes")
        }
        return denied
    }

    var activitySpace: String {
        space.name
    }
}

import Foundation

public extension MeetDeviceSession {
    var localCaptionLanguages: MeetCaptionWire.Languages? {
        device?.captionLanguages
    }

    struct AdmissionState: Sendable, Equatable {
        public let joinState: UInt64
        public let transfer: UInt64
        public let isDeleted: Bool
    }

    var admissionState: AdmissionState? {
        device.map { AdmissionState(joinState: $0.joinState, transfer: $0.transfer, isDeleted: $0.isDeleted) }
    }

    var pendingAdmissionAcknowledgements: [MeetDeviceWire.Acknowledgement] {
        guard device?.joinState == 9, device?.isDeleted == false else { return [] }
        return device?.acknowledgements.filter {
            $0.state == 1 && !acknowledgedAdmissionTypes.contains($0.type)
        } ?? []
    }

    func refreshAdmission() async throws {
        try begin()
        defer { busy = false }
        guard mediaConnected, let device,
              device.joinState == 9 else { throw MeetDeviceSessionError.notJoined }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: MeetCallCollectionsWire.sync(space: space.name)
        )
        guard let read = try MeetCallCollectionsWire.admissionRead(
                  from: response.body, in: space.name, name: device.name
              ), let current = read.device, !current.isDeleted,
              read.version >= (waitingAdmissionVersion ?? 0),
              read.version != waitingAdmissionVersion || current.joinState == device.joinState,
              [1, 9].contains(current.joinState) else { throw MeetDeviceSessionError.notJoined }
        try acceptAdmissionDevice(current)
        if waitingAdmissionVersion != nil {
            waitingAdmissionVersion = read.version
        }
    }

    /// This read never advances a different device or accepts a delta as admission.
    func refreshWaitingAdmission() async throws -> Bool {
        try await refreshWaitingAdmission(includingMessages: false).observed
    }

    struct WaitingAdmissionRead: Sendable {
        public let observed: Bool
        public let messages: [Data]?
        public let messageVersion: UInt64?
    }

    func refreshWaitingAdmission(includingMessages: Bool) async throws -> WaitingAdmissionRead {
        try begin()
        defer { busy = false }
        guard mediaConnected, let device, [3, 13].contains(device.joinState), !device.isDeleted else {
            throw MeetDeviceSessionError.notJoined
        }
        let includeMessages = includingMessages && device.joinState == 13 && !device.isPresentation
        var body = MeetProto.string(1, space.name) + MeetProto.bytes(3, Data())
        if includeMessages {
            body += MeetProto.bytes(4, Data())
        }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: body, timeout: .seconds(8)
        )
        try Task.checkCancellation()
        guard let read = try MeetCallCollectionsWire.admissionRead(
            from: response.body, in: space.name, name: device.name
        ), let observed = read.device, read.version >= (waitingAdmissionVersion ?? 0) else {
            return WaitingAdmissionRead(observed: false, messages: nil, messageVersion: nil)
        }
        if read.version == waitingAdmissionVersion {
            guard observed.joinState == device.joinState, !observed.isDeleted else {
                return WaitingAdmissionRead(observed: false, messages: nil, messageVersion: nil)
            }
        } else {
            try acceptAdmissionDevice(observed)
            waitingAdmissionVersion = read.version
        }
        let snapshot = includeMessages && observed.joinState == 13 && !observed.isDeleted && !observed
            .isPresentation
            ? try? MeetActivityCollections.availableSnapshot(response.body, space: space.name) : nil
        return WaitingAdmissionRead(
            observed: true,
            messages: snapshot?.messages,
            messageVersion: snapshot?.versions[3]
        )
    }

    func acknowledgeAdmission(_ requirements: [MeetDeviceWire.Acknowledgement]) async throws {
        try begin()
        defer { busy = false }
        guard mediaConnected, let device, !requirements.isEmpty,
              requirements == pendingAdmissionAcknowledgements,
              acknowledgedAdmissionTypes.isDisjoint(with: requirements.map(\.type))
        else { throw MeetDeviceSessionError.notJoined }
        let body = try MeetDeviceWire.acknowledge(device: device.name, requirements: requirements)
        acknowledgedAdmissionTypes.formUnion(requirements.map(\.type))
        let response = try await send("MeetingDeviceService/UpdateMeetingDevice", body: body, isDevice: true)
        let updated = try MeetDeviceWire.device(from: response.body, in: space.name)
        try acceptAdmissionDevice(updated)
        guard !updated.isDeleted else { throw MeetDeviceSessionError.notJoined }
    }
}

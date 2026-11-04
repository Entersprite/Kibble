import Foundation

public extension MeetDeviceSession {
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
        guard let current = try MeetCallCollectionsWire.admissionDevice(
            from: response.body, in: space.name, name: device.name
        ), !current.isDeleted,
        [1, 9].contains(current.joinState) else { throw MeetDeviceSessionError.notJoined }
        try acceptAdmissionDevice(current)
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

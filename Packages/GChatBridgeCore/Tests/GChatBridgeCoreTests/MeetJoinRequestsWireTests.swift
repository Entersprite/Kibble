import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetJoinRequestsWireTests {
    @Test(arguments: [true, false])
    func joinRequestsWriteOnlyTheTwoKnockingPolicies(_ enabled: Bool) throws {
        let request = try MeetActivityWire.hostSetting(
            .allowJoinRequests, space: "spaces/demo", enabled: enabled, requestID: UUID()
        )
        let space = try MeetProto.payload(1, request.body)
        let active = try MeetProto.payload(11, MeetProto.payload(6, space))
        let saved = try MeetProto.payload(15, space)
        let expected: UInt64 = enabled ? 2 : 1
        #expect(request.method == "MeetingSpaceService/UpdateMeetingSpace")
        #expect(active == MeetProto.number(40, expected))
        #expect(saved == MeetProto.number(38, expected))
        let mask = try MeetProto.payload(2, request.body)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: mask) == [
            Data("call_info.settings.knocking_setting".utf8), Data("settings.knocking_setting".utf8)
        ])
        #expect(MeetActivityWire.joinRequestsAllowed(in: space, saved: true) == enabled)
    }

    @Test func unsupportedMissingAndAmbiguousJoinRequestPoliciesStayUnknown() {
        let allowed = MeetProto.number(40, 2)
        let trusted = MeetProto.number(12, 2)
        let restricted = MeetProto.number(12, 3)
        let missingOrAmbiguous: [Data] = [
            Data(), trusted, trusted + MeetProto.number(40, 0), trusted + allowed + allowed
        ]
        let unsupportedPreset: [Data] = [MeetProto.number(12, 1) + allowed, MeetProto.number(12, 4) + allowed]
        let restrictedSettings = restricted + allowed
        let unsupportedScaling: [Data] = [
            restrictedSettings + MeetProto.number(49, 2), restrictedSettings + MeetProto.number(49, 3),
            restrictedSettings + MeetProto.bytes(49, Data())
        ]
        for settings in missingOrAmbiguous + unsupportedPreset + unsupportedScaling {
            let space = MeetProto.bytes(6, MeetProto.bytes(11, settings))
            #expect(MeetActivityWire.joinRequestsAllowed(in: space) == nil)
        }
        let trustedSpace = MeetProto.bytes(6, MeetProto.bytes(11, trusted + allowed))
        let restrictedSpace = MeetProto.bytes(6, MeetProto.bytes(11, restricted + MeetProto.number(40, 1)))
        #expect(MeetActivityWire.joinRequestsAllowed(in: trustedSpace) == true)
        #expect(MeetActivityWire.joinRequestsAllowed(in: restrictedSpace) == false)
    }
}

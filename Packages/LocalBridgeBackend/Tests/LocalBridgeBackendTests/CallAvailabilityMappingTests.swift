import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CallAvailabilityMappingTests {
    @Test func onlyRecognizedConversationStateEstablishesAnActiveHuddle() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var call = CallSpaceIntegrationPayload()
        call.callStatus = 1
        let unknown = CallAvailabilityMapping.map(call, in: .init("room"), at: date)
        #expect(unknown.status == .unknown("unrecognized"))
        call.callMetadata.meetMetadata.meetingType = 1
        call.callMetadata.meetMetadata.meetingCode = "aaa-bbbb-ccc"
        call.callMetadata.meetMetadata.meetingURL = "https://meet.google.com/aaa-bbbb-ccc"
        let active = CallAvailabilityMapping.map(call, in: .init("room"), at: date)
        #expect(active.status == .active)
        #expect(active.reference == "aaa-bbbb-ccc")
        #expect(active.joinURL?.absoluteString == "https://meet.google.com/aaa-bbbb-ccc")
        #expect(active.participants == nil)
        call.callStatus = 3
        #expect(CallAvailabilityMapping.map(call, in: .init("room"), at: date).status == .inactive)
        let missing = CallAvailabilityMapping.map(nil, in: .init("room"), at: date)
        #expect(missing.status == .unknown("unavailable"))
    }

    @Test func duplicatedEnvelopesAndUnsafeLinksRemainUnusable() {
        var call = CallSpaceIntegrationPayload()
        call.callStatus = 1
        call.callMetadata.meetMetadata.meetingType = 1
        call.callMetadata.meetMetadata.meetingCode = "aaa-bbbb-ccc"
        call.callMetadata.meetMetadata.meetingURL = "https://meet.google.com/wrong-code"
        let value = CallAvailabilityMapping.map(call, in: .init("room"), at: .distantPast)
        #expect(value.joinURL == nil)
        var envelope = SpaceIntegrationPayload()
        envelope.type = 5; envelope.callIntegrationPayload = call
        var group = Group(); group.spaceIntegrationPayloads = [envelope]
        #expect(CallAvailabilityMapping.payload(in: group) == call)
        group.spaceIntegrationPayloads.append(envelope)
        #expect(CallAvailabilityMapping.payload(in: group) == nil)
    }
}

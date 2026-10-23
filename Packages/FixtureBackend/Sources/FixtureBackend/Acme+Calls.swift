import ChatKit
import Foundation

/// The demo's call going on in storefront-web, for a session that wants one:
/// four other devices, one muted, one whose microphone was never reported,
/// and one sharing a screen. Literal identifiers, so the demo is the same
/// every time.
public extension Acme {
    static let storefrontCallDevices: [CallParticipantDevice] = [
        CallParticipantDevice(id: device(1), displayName: "Maya Okafor", microphoneMuted: false),
        CallParticipantDevice(id: device(2), displayName: "Dan Reyes", microphoneMuted: true),
        CallParticipantDevice(id: device(3), displayName: "Priya Shah"),
        CallParticipantDevice(id: device(4), displayName: "Tom Whitfield", microphoneMuted: false),
        CallParticipantDevice(
            id: device(5), displayName: "Maya Okafor", parentID: device(1), isPresentation: true
        )
    ]

    /// Scripts the call into a fixture backend and its call service: the
    /// backend's discovery answers that it is going on, and a join reports
    /// its devices.
    @MainActor
    static func scriptStorefrontCall(backend: FakeBackend, calls: FixtureAudioCallService) async {
        calls.setExistingCallParticipants(storefrontCallDevices, in: storefront)
        let people = [maya, dan, priya, tom].map { ConversationCallParticipant(memberID: $0) }
        await backend.setCallAvailability(ConversationCallAvailability(
            conversationID: storefront, status: .active, checkedAt: start,
            participants: people, totalParticipants: people.count
        ))
    }

    private static func device(_ number: UInt8) -> UUID {
        UUID(uuid: (0xCA, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, number))
    }
}

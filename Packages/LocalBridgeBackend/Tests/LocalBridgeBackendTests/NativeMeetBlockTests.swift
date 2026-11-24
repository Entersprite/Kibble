import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetBlockTests {
    private let own = "spaces/demo/devices/one"
    private let guest = "spaces/demo/devices/guest"
    private let sibling = "spaces/demo/devices/guest-browser"
    private let other = "spaces/demo/devices/other"

    @Test(arguments: [true, false])
    func blockAddressesOneDeviceAndWaitsForTheOrdinaryMembershipRead(_ managed: Bool) async throws {
        let local = device(own, user: "100") + NativeMeetFixture.number(13, 1)
            + NativeMeetFixture.number(46, managed ? 5 : 3)
        let present = [local, device(guest, user: "200"), device(sibling, user: "200"), device(other)]
        let start = NativeMeetGuestAdmissionTests.collection(1, present)
        let changed = device(guest, state: 7)
        let changedSibling = device(sibling, state: 7)
        let after = NativeMeetGuestAdmissionTests.collection(
            2,
            [local, changed, changedSibling, device(other)]
        )
        let receipt = blockReply([changed, changedSibling])
        let (session, transport) = try await connect([start, start, receipt, after])
        await session.refreshState()
        let id = try #require(await session.participantHandles[guest])
        #expect(await session.activities.availableActions.contains("blockParticipant"))
        #expect(await session.publishedParticipants?.first { $0.id == id }?.canBlockInMeeting == true)
        try await session.performActivity(CallActivity("blockParticipant", resourceID: id))
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "BlockUser")
        #expect(request.body == NativeMeetFixture.string(1, guest))
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(await session.publishedParticipants?.count == 4)
        await session.refreshState()
        #expect(await session.publishedParticipants?.count == 2)
        #expect(await session.participantHandles[guest] == nil)
        #expect(await session.participantHandles[sibling] == nil)
        #expect(await session.state == .active)
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "BlockUser" }
            .count == 1)
        #expect(await transport.sent.dropFirst(4)
            .allSatisfy { $0.url.lastPathComponent != "UpdateMeetingDevice" })
        await session.close()
    }

    @Test(arguments: [
        "grant-revoked",
        "same-account",
        "self",
        "presentation",
        "stale",
        "departed",
        "unknown"
    ])
    func blockChecksFreshAuthorityAndAnEligibleOtherUser(_ scenario: String) async throws {
        let ownDevice = device(own, user: "100") + NativeMeetFixture.number(46, 1)
        let grant = NativeMeetFixture.number(13, 1)
        let start = NativeMeetGuestAdmissionTests.collection(2, [
            ownDevice + grant, device(guest, user: "200")
        ])
        let candidate = switch scenario {
        case "same-account": device(guest) + NativeMeetFixture.string(49, "000100")
        case "presentation": device(guest) + NativeMeetFixture.number(25, 2)
        case "departed": device(guest, state: 6)
        default: device(guest, user: "200")
        }
        let acting = ownDevice + (scenario == "grant-revoked" ? Data() : grant)
        let checked = NativeMeetGuestAdmissionTests.collection(
            scenario == "stale" ? 1 : 3, [acting, candidate]
        )
        let (session, transport) = try await connect([start, checked])
        await session.refreshState()
        let id = try #require(await session.participantHandles[scenario == "self" ? own : guest])
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity(
                "blockParticipant", resourceID: scenario == "unknown" ? UUID() : id
            ))
        }
        #expect(await transport.sent.allSatisfy { $0.url.lastPathComponent != "BlockUser" })
        await session.close()
    }

    @Test(arguments: ["empty", "foreign", "unaddressed", "duplicate", "joined", "own", "malformed"])
    func ambiguousBlockReceiptsCannotChangePeopleOrTriggerASecondWrite(_ scenario: String) async throws {
        let local = device(own) + NativeMeetFixture.number(13, 1)
        let roster = NativeMeetGuestAdmissionTests.collection(1, [local, device(guest), device(other)])
        let changed = device(guest, state: 7)
        let receipt = switch scenario {
        case "empty": blockReply([])
        case "foreign": blockReply([changed, device("spaces/foreign/devices/guest", state: 7)])
        case "unaddressed": blockReply([device(sibling, state: 7)])
        case "duplicate": blockReply([changed, changed])
        case "joined": blockReply([device(guest)])
        case "own": blockReply([changed, device(own, state: 7)])
        default: NativeMeetFixture.ok(NativeMeetFixture.number(1, 7))
        }
        let rechecks = ["empty", "unaddressed", "joined"].contains(scenario)
        let replies = [roster, roster, receipt] + (rechecks ? [roster] : [])
        let (session, transport) = try await connect(replies)
        await session.refreshState()
        let id = try #require(await session.participantHandles[guest])
        let beforeBlock = await transport.sent.count
        let action = CallActivity("blockParticipant", resourceID: id)
        if rechecks {
            await #expect(throws: ChatError.transport("The block could not be confirmed.")) {
                try await session.performActivity(action)
            }
        } else {
            await #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try await session.performActivity(action)
            }
        }
        #expect(await session.publishedParticipants?.contains { $0.id == id } == true)
        let requests = await transport.sent.dropFirst(beforeBlock)
        let methods = ["SyncMeetingSpaceCollections", "BlockUser"] +
            (rechecks ? ["SyncMeetingSpaceCollections"] : [])
        #expect(requests.map(\.url.lastPathComponent) == methods)
        await session.close()
    }

    @Test func aValidReceiptWithoutTheTargetRequiresNewerMembershipReadback() async throws {
        let local = device(own) + NativeMeetFixture.number(13, 1)
        let present = NativeMeetGuestAdmissionTests.collection(1, [local, device(guest), device(other)])
        let absent = NativeMeetGuestAdmissionTests.collection(2, [local, device(other)])
        let (session, transport) = try await connect([present, present, blockReply([]), absent, absent])
        await session.refreshState()
        let id = try #require(await session.participantHandles[guest])
        try await session.performActivity(CallActivity("blockParticipant", resourceID: id))
        #expect(await transport.sent.last?.url.lastPathComponent == "SyncMeetingSpaceCollections")
        #expect(await session.publishedParticipants?.count == 3)
        await session.refreshState()
        #expect(await session.publishedParticipants?.count == 2)
        #expect(await session.state == .active)
        await session.close()
    }

    private func connect(_ replies: [Result<HTTPResponse, any Error>]) async throws
        -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + replies + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(
            transport,
            media: NativeFakeMedia(),
            staysWhenAlone: true
        )
        try await session.connect()
        return (session, transport)
    }

    private func device(_ name: String, state: UInt64 = 1, user: String? = nil) -> Data {
        let basic = NativeMeetFixture.string(1, name) + NativeMeetFixture.number(4, state)
        return basic + (user.map {
            NativeMeetFixture.bytes(55, NativeMeetFixture.string(2, $0))
        } ?? Data())
    }

    private func blockReply(_ devices: [Data]) -> Result<HTTPResponse, any Error> {
        NativeMeetFixture.ok(devices.reduce(into: Data()) { $0 += NativeMeetFixture.bytes(1, $1) })
    }
}

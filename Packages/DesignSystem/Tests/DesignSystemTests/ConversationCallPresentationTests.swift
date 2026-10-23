import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// Join and Return to Call in the header and the menu bar, who is in a group
/// or space call, and where several videos go.
@MainActor
struct ConversationCallPresentationTests {
    private let id = Conversation.ID("opaque-space")

    private func state(_ offer: ConversationCallOffer?, callable: Bool = true) -> ChatSceneState {
        var state = ChatSceneState(
            conversations: [Conversation(id: id, kind: .space, title: "Design")], selected: id,
            callableConversations: callable ? [id] : []
        )
        state.callOffer = offer
        return state
    }

    private func actions(join: Bool = true, back: Bool = true) -> ChatSceneActions {
        var actions = ChatSceneActions(call: { _ in })
        actions.videoCall = { _ in }
        actions.joinCall = join ? { _ in } : nil
        actions.returnToCall = back ? {} : nil
        return actions
    }

    private func window(_ offer: ConversationCallOffer?, join: Bool = true, back: Bool = true) -> ChatWindow {
        ChatWindow(state: state(offer), actions: actions(join: join, back: back))
    }

    private func entry(_ slot: String, _ offer: ConversationCallOffer?) -> ConversationMenuBar.Entry? {
        ConversationMenuBar(state: state(offer), actions: actions()).sections.flatMap(\.self)
            .first { $0.id == slot }
    }

    // MARK: Header

    @Test func aFreshJoinReplacesCallWithJoin() {
        let joining = window(.join(participants: 3))
        #expect(joining.joinConversation?.id == id)
        #expect(joining.joinConversation?.participants == 3)
        #expect(joining.callConversation == nil)
        #expect(joining.videoCallConversation == nil)
        #expect(!joining.showsReturnToCall)
    }

    @Test func theSessionsOwnCallOffersOnlyReturnToCall() {
        let inCall = window(.returnToCall)
        #expect(inCall.showsReturnToCall)
        #expect(inCall.joinConversation == nil)
        #expect(inCall.callConversation == nil)
    }

    @Test func withoutTheActionsTheHeaderFallsBackToCall() {
        #expect(window(.join(participants: nil), join: false).callConversation == id)
        #expect(window(.join(participants: nil), join: false).joinConversation == nil)
        #expect(window(.returnToCall, back: false).callConversation == id)
        #expect(!window(.returnToCall, back: false).showsReturnToCall)
    }

    @Test func noOfferOrAnUncallableConversationShowsCallOnlyWhereCallable() {
        #expect(window(nil).callConversation == id)
        #expect(window(.call).callConversation == id)
        let uncallable = ChatWindow(state: state(.call, callable: false), actions: actions())
        #expect(uncallable.callConversation == nil)
        #expect(uncallable.joinConversation == nil)
    }

    @Test func joinsHelpSaysWhoIsThereOnlyWhenCounted() {
        let uncounted = "Join the call going on in this conversation"
        #expect(ConversationCallOffer.joinHelp(participants: nil) == uncounted)
        #expect(ConversationCallOffer.joinHelp(participants: 0) == uncounted)
        #expect(ConversationCallOffer.joinHelp(participants: 1) == "Join the call; 1 person is in it")
        #expect(ConversationCallOffer.joinHelp(participants: 4) == "Join the call; 4 people are in it")
    }

    // MARK: Menu bar

    @Test func theMenuBarEnablesExactlyWhatTheHeaderOffers() {
        #expect(entry("call", .call)?.command == .call(id))
        #expect(entry("joinCall", .call)?.isEnabled == false)
        #expect(entry("returnToCall", .call)?.isEnabled == false)
        #expect(entry("call", .join(participants: 2))?.isEnabled == false)
        #expect(entry("videoCall", .join(participants: 2))?.isEnabled == false)
        #expect(entry("joinCall", .join(participants: 2))?.command == .joinCall(id))
        #expect(entry("returnToCall", .returnToCall)?.command == .returnToCall)
        #expect(entry("call", .returnToCall)?.isEnabled == false)
    }

    @Test func aHostWithoutJoinDrawsNoJoinItem() {
        let entries = ConversationMenuBar(state: state(.call), actions: ChatSceneActions(call: { _ in }))
            .sections.flatMap(\.self).map(\.id)
        #expect(!entries.contains("joinCall"))
        #expect(!entries.contains("returnToCall"))
    }

    // MARK: Roster

    @Test func theRosterListsOtherDevicesAndMarksWhoShares() throws {
        let maya = UUID(), dan = UUID(), mine = UUID(), screen = UUID()
        let entries = try #require(CallRoster.entries([
            CallParticipantDevice(id: maya, displayName: "Maya", microphoneMuted: false),
            CallParticipantDevice(id: mine, displayName: "Me", isLocal: true),
            CallParticipantDevice(id: dan, displayName: " ", microphoneMuted: true),
            CallParticipantDevice(id: screen, displayName: "Maya", parentID: maya, isPresentation: true)
        ]))
        #expect(entries.map(\.id) == [maya, dan])
        #expect(entries.map(\.name) == ["Maya", "Participant"])
        #expect(entries.first?.isPresenting == true)
        #expect(entries.last?.isPresenting == false)
        #expect(entries.map(CallRoster.showsMuted) == [false, true])
    }

    @Test func anUnknownMicrophoneIsNeverDrawnMuted() throws {
        let device = CallParticipantDevice(id: UUID(), displayName: "Priya")
        let entries = try #require(CallRoster.entries([device]))
        #expect(entries[0].microphoneMuted == nil)
        #expect(!CallRoster.showsMuted(entries[0]))
        #expect(CallPeopleList.label(for: entries[0]) == "Priya")
    }

    @Test func anUnestablishedRosterIsNotAnEmptyRoom() {
        #expect(CallRoster.entries(nil) == nil)
        #expect(CallRoster.summary(nil) == nil)
        #expect(CallRoster.summary([]) == "Waiting for others to join")
        let entries = ["Ann", "Ben", "Cy"].map { CallRosterEntry(
            id: UUID(), name: $0, microphoneMuted: nil, isPresenting: false
        ) }
        #expect(CallRoster.summary(Array(entries.prefix(1))) == "With Ann")
        #expect(CallRoster.summary(Array(entries.prefix(2))) == "With Ann and Ben")
        #expect(CallRoster.summary(entries) == "With Ann and 2 others")
    }

    @Test func theRosterKeepsItsOrderWhateverOrderTheProviderSends() {
        let devices = ["Zoe", "amir", "Bea"].map { CallParticipantDevice(id: UUID(), displayName: $0) }
        #expect(CallRoster.entries(devices)?.map(\.name) == ["amir", "Bea", "Zoe"])
        #expect(CallRoster.entries(devices.reversed())?.map(\.name) == ["amir", "Bea", "Zoe"])
    }

    @Test func initialsAreTwoLettersAtMost() {
        #expect(CallRosterFace.initials("Maya Okafor") == "MO")
        #expect(CallRosterFace.initials("maya") == "M")
        #expect(CallRosterFace.initials("Ana María López") == "AM")
        #expect(CallRosterFace.initials("") == "?")
    }

    // MARK: Stage

    private func video(_ slot: Int, screen: Bool = false, owner: UUID? = nil) -> CallRemoteVideo {
        CallRemoteVideo(
            id: slot, participantID: owner, label: "Person \(slot)", isScreen: screen,
            content: AnyView(Color.clear)
        )
    }

    @Test func oneVideoFillsTheStageAndAScreenTakesItWithCamerasBeside() {
        #expect(CallStageLayout.of([]) == .none)
        #expect(CallStageLayout.of([video(0)]) == .single)
        #expect(CallStageLayout.of([video(0, screen: true)]) == .single)
        let mixed = [video(0), video(1, screen: true), video(2)]
        #expect(CallStageLayout.of(mixed) == .presentation)
        #expect(CallStageLayout.main(of: mixed)?.id == 1)
        #expect(CallStageLayout.alongside(mixed).map(\.id) == [0, 2])
        #expect(CallStageLayout.alongside([video(0)]).isEmpty)
    }

    @Test(arguments: [(2, 2), (3, 2), (4, 2), (5, 3), (8, 3), (9, 3)])
    func camerasShareAGrid(_ count: Int, _ columns: Int) {
        let videos = (0 ..< count).map { video($0) }
        #expect(CallStageLayout.of(videos) == .grid(columns: columns))
        #expect(CallStageLayout.main(of: videos) == nil)
        #expect(CallStageLayout.alongside(videos).isEmpty)
    }

    @Test func aCameraTileShowsAReportedMuteAndAScreenNever() {
        let owner = UUID()
        let roster = [CallRosterEntry(id: owner, name: "Dan", microphoneMuted: true, isPresenting: true)]
        #expect(CallRoster.isMuted(video(0, owner: owner), in: roster))
        #expect(!CallRoster.isMuted(video(1, screen: true, owner: owner), in: roster))
        #expect(!CallRoster.isMuted(video(2, owner: UUID()), in: roster))
        #expect(!CallRoster.isMuted(video(3), in: roster))
        #expect(!CallRoster.isMuted(video(0, owner: owner), in: nil))
        #expect(CallVideoTile.label(for: video(0), muted: true) == "Person 0’s camera, muted")
        #expect(CallVideoTile.label(for: video(1, screen: true), muted: false) == "Person 1’s shared screen")
    }

    // MARK: Status and sharing

    @Test func aJoinSaysJoiningUntilItConnects() {
        let target = ConversationCallTarget(conversationID: id, displayName: "Design")
        var call = AudioCallSession(
            ConversationCallSnapshot(id: UUID(), target: target, phase: .connecting),
            isJoining: true
        )
        #expect(AudioCallPresentation.status(for: call) == "Joining…")
        call.isJoining = false
        #expect(AudioCallPresentation.status(for: call) == "Connecting…")
        call.isJoining = true
        call.phase = .connected
        #expect(AudioCallPresentation.status(for: call) == "Connected")
    }

    @Test func shareWithSoundIsItsOwnItemOnlyWhereOfferedAndIdle() {
        let call = AudioCallSession(ConversationCallSnapshot(
            id: UUID(), target: ConversationCallTarget(conversationID: id, displayName: "Design"),
            phase: .connected
        ))
        func items(_ sharing: CallScreenShareState.Phase, sound: Bool) -> [CallMenu.Item: Bool] {
            let menu = CallMenu(
                call: call, isEnding: false, camera: CallCameraState(),
                screenSharing: CallScreenShareState(phase: sharing), offersVideo: true, offersSound: sound
            )
            return Dictionary(uniqueKeysWithValues: menu.entries.map { ($0.item, $0.isEnabled) })
        }
        #expect(items(.idle, sound: false)[.shareScreenWithSound] == nil)
        #expect(items(.idle, sound: true)[.shareScreenWithSound] == true)
        #expect(items(.sharing, sound: true)[.shareScreenWithSound] == false)
        #expect(items(.preparing, sound: true)[.shareScreenWithSound] == false)
        #expect(CallMenu.shareWithSoundTitle == "Share Screen with Sound…")
    }

    // MARK: Window

    #if os(macOS)
        /// A full roster keeps the audio window's width, and its faces fit in it.
        @Test func aGroupCallsRosterKeepsTheCompactWidth() {
            let target = ConversationCallTarget(conversationID: id, displayName: "A rather long space name")
            let devices = (0 ..< 6).map {
                CallParticipantDevice(id: UUID(), displayName: "Person Number \($0)", microphoneMuted: true)
            }
            let view = AudioCallView(
                call: AudioCallSession(ConversationCallSnapshot(
                    id: UUID(),
                    target: target,
                    phase: .connected
                )),
                actions: AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {}),
                conversation: Conversation(id: id, kind: .space, title: "A rather long space name"),
                participants: devices
            )
            let size = NSHostingView(rootView: view).fittingSize
            #expect(size.width == CallLayout.compact.width)
            let strip = NSHostingView(rootView: CallRosterStrip(
                entries: CallRoster.entries(devices) ?? [], showPeople: {}
            )).fittingSize
            #expect(strip.width <= CallLayout.compact.width - 40)
        }
    #endif
}

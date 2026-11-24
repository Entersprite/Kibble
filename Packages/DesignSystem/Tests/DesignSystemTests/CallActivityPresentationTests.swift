import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallActivityPresentationTests {
    @Test(arguments: CallActivityTab.allCases)
    func activityTabsRenderOffscreen(_ tab: CallActivityTab) async throws {
        let name = tab.rawValue.replacingOccurrences(of: "&", with: "and")
        try await render(sampleState(), tab: tab, name: name)
    }

    @Test func pinnedChatRendersTheAddressedControlAndKeepsTheComposer() async throws {
        var state = sampleState()
        state.availableActions.append("setMeetingMessagePin")
        state.messages.append(CallMeetingMessage(
            id: UUID(), sender: "You", text: "Review the agenda before Friday.",
            isPinned: true, canChangePin: true
        ))
        try await render(state, tab: .chat, name: "ChatPinned")
    }

    @Test(arguments: [true, false])
    func continuousChatRendersInTheSameActivitiesTab(_ canSend: Bool) async throws {
        var state = sampleState()
        let id = Conversation.ID("space/meeting")
        state.meetingChat = CallMeetingChat(conversationID: id, canSend: canSend)
        let message = Message(
            id: .init("saved-message"), conversationID: id, threadID: .init(""), sender: .init("me"),
            text: "Can everyone review the agenda?", createdAt: Date(timeIntervalSince1970: 0)
        )
        let chat = CallChatScene(
            messages: [message], directory: [:], me: .init("me"), draft: "", isSending: false, error: nil,
            updateDraft: { _ in }, send: canSend ? {} : nil, open: {}, close: {}
        )
        try await render(
            state,
            tab: .chat,
            name: canSend ? "ContinuousChat" : "ContinuousChatReadOnly",
            chat: chat
        )
    }

    @Test func recordingCaptionPickerRendersBeforeStarting() async throws {
        var state = sampleState()
        state.recordingCaptionLanguages = ["en-US", "fr-FR"]
        state.artifacts[0].phase = "stopped"
        try await render(state, tab: .meeting, name: "RecordingCaptions")
    }

    @Test func cohostActionsAndRoleLabelsRenderInThePeopleList() throws {
        let devices = [
            CallParticipantDevice(id: UUID(), displayName: "Dan Reyes", microphoneMuted: true, role: .cohost),
            CallParticipantDevice(
                id: UUID(),
                displayName: "Maya Okafor",
                role: .participant,
                canBlockInMeeting: true
            ),
            CallParticipantDevice(id: UUID(), displayName: "Taylor", role: .host),
            CallParticipantDevice(id: UUID(), displayName: "Priya Shah")
        ]
        let entries = try #require(CallRoster.entries(devices))
        #expect(entries.map(\.cohostChange) == [false, true, nil, nil])
        #expect(entries.map(\.canBlockInMeeting) == [false, true, false, false])
        #expect(entries.map(CallPeopleList.label(for:)) == [
            "Dan Reyes, Co-host, muted",
            "Maya Okafor",
            "Priya Shah",
            "Taylor, Host"
        ])
        var state = CallActivitiesState()
        state.availableActions = [
            "setCohost", "muteParticipant", "muteAllParticipants", "removeParticipant", "blockParticipant"
        ]
        try renderPeople(state, entries: entries, height: 196, name: "PeopleCohosts")
    }

    @Test func waitingRequestsAndWaitingRoomRenderInThePeopleList() throws {
        var state = CallActivitiesState()
        state.availableActions = ["respondToAdmission", "respondToAdmissions"]
        state.waitingParticipants = [
            CallWaitingParticipant(id: UUID(), name: "Maya Okafor", canDeny: true),
            CallWaitingParticipant(id: UUID(), name: "Dan Reyes", canDeny: true, warning: .suspectedBot),
            CallWaitingParticipant(id: UUID(), name: "Priya Shah", canDeny: false)
        ]
        let entries = try #require(CallRoster.entries([
            CallParticipantDevice(id: UUID(), displayName: "Taylor", role: .host)
        ]))
        try renderPeople(state, entries: entries, height: 300, name: "PeopleWaiting")
    }

    @Test func sharedPinsRenderInPeopleAlongsideTheExistingRoster() throws {
        var state = CallActivitiesState()
        state.availableActions = ["setPinForEveryone"]
        let own = CallParticipantDevice(id: UUID(), isLocal: true, isPinnedForEveryone: false)
        let peer = CallParticipantDevice(id: UUID(), displayName: "Taylor", isPinnedForEveryone: true)
        let screen = CallParticipantDevice(
            id: UUID(), parentID: peer.id, isPresentation: true, isPinnedForEveryone: false
        )
        let devices = [own, peer, screen]
        let entries = try #require(CallRoster.entries(devices))
        #expect(entries
            .map(CallPeopleList.label(for:)) == ["Taylor, sharing their screen, pinned for everyone"])
        try renderPeople(state, entries: entries, height: 140, name: "PeopleSharedPins", pinTargets: devices)
    }

    @Test func raisedHandsUseProviderOrderAndRenderModeratorControls() throws {
        var state = CallActivitiesState()
        state.availableActions = ["lowerParticipantHand", "lowerAllHands"]
        let devices = [
            CallParticipantDevice(id: UUID(), displayName: "Taylor", handRaised: true),
            CallParticipantDevice(
                id: UUID(), displayName: "Avery", handRaised: true,
                handRaisedAt: .init(timeIntervalSince1970: 2)
            ),
            CallParticipantDevice(
                id: UUID(), displayName: "Maya", handRaised: true,
                handRaisedAt: .init(timeIntervalSince1970: 1)
            ),
            CallParticipantDevice(id: UUID(), displayName: "Robin")
        ]
        let entries = try #require(CallRoster.entries(devices))
        #expect(CallRoster.raisedHands(entries).map(\.name) == ["Maya", "Avery", "Taylor"])
        try renderPeople(state, entries: entries, height: 240, name: "PeopleRaisedHands")
    }

    @Test func handLoweringNoticesSkipWindowBootstrapAndRetireIndependently() {
        let old = UUID(), first = UUID(), next = UUID()
        var presentation = CallHandLoweringPresentation(previous: old)
        func receive(_ event: UUID?, shows expected: Bool) {
            let showsNotice = presentation.receive(event)
            #expect(showsNotice == expected)
        }
        receive(old, shows: false)
        #expect(presentation.visible == nil)
        receive(first, shows: true)
        receive(nil, shows: false)
        receive(first, shows: false)
        receive(next, shows: true)
        presentation.dismiss(first)
        #expect(presentation.visible == next)
        presentation.dismiss(next)
        #expect(presentation.visible == nil)
        receive(next, shows: false)
    }

    @Test func onlyAFreshHandLoweringRendersInTheCallNoticeSlot() throws {
        let host = NSHostingView(rootView: CallHandLoweredNotice(event: UUID()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        #expect(host.fittingSize.height == 0)
        host.rootView = CallHandLoweredNotice(event: UUID())
        settle()
        #expect(host.fittingSize.height >= 25)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("HandLowered.png"))
        }
        withExtendedLifetime(window) {}
    }

    @Test func automaticHandLoweringRendersTheCountdownAndCancellation() throws {
        let prompt = CallAutomaticHandLowering(id: UUID(), deadline: Date().addingTimeInterval(10))
        let host = NSHostingView(rootView: CallAutomaticHandPrompt(prompt: prompt, perform: { _ in })
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .padding(4).background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        #expect(host.frame.height > 48)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("AutomaticHand.png"))
        }
    }

    @Test func cameraGestureProgressRendersInTheCallNoticeSlot() throws {
        let host = NSHostingView(rootView: VStack {
            CallHandFeedback(
                scene: nil,
                participants: nil,
                gestureProgress: 0.5,
                showsPeople: .constant(false)
            )
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .padding(4).background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        #expect(host.frame.height >= 25)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("HandGestureProgress.png"))
        }
    }

    private func renderPeople(
        _ state: CallActivitiesState, entries: [CallRosterEntry], height: CGFloat, name: String,
        pinTargets: [CallParticipantDevice]? = nil
    ) throws {
        let view = CallPeopleList(
            entries: entries, activities: .init(state: state, perform: { _ in }), pinTargets: pinTargets
        )
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame.size = NSSize(width: CallPeopleList.width, height: height)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func render(
        _ state: CallActivitiesState, tab: CallActivityTab, name: String, chat: CallChatScene? = nil
    ) async throws {
        let view = CallActivitiesView(
            scene: CallActivitiesScene(
                state: state, meetingChat: chat,
                setRecordingAndTranscriptionEnabled: { _, _ in },
                perform: { _ in }
            ),
            initialTab: tab
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = NSSize(width: 520, height: 620)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CALL_ACTIVITY_RENDERS"] {
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func sampleState() -> CallActivitiesState {
        var state = CallActivitiesState()
        state.availableActions = [
            "react",
            "chat",
            "recording",
            "transcription",
            "notes",
            "attendance",
            "createPoll",
            "votePoll",
            "closePoll", "sharePollResults",
            "askQuestion",
            "voteQuestion",
            "answerQuestion",
            "createRooms",
            "openRooms",
            "closeRooms",
            "assignRoom"
        ]
        state.artifacts = [
            CallArtifact(kind: "recording", phase: "active"),
            CallArtifact(kind: "transcription", phase: "active"),
            CallArtifact(
                kind: "notes",
                phase: "stopped"
            )
        ]
        if let url = URL(string: "https://drive.google.com/file/d/synthetic-recording/view") {
            state.artifactFiles = [.init(kind: "recording", title: "Design review recording", url: url)]
        }
        state.messages = [CallMeetingMessage(id: UUID(), sender: "Taylor", text: "Meeting notes are ready.")]
        state.polls = [CallPoll(
            id: UUID(),
            question: "Which option?",
            options: ["One", "Two"],
            votes: [2, 3],
            isOpen: true, resultsVisible: false
        )]
        state.allowsAnonymousQuestions = true
        state.questions = [CallQuestion(id: UUID(), text: "When do we start?", votes: 3)]
        state.rooms = [CallBreakoutRoom(
            id: UUID(),
            name: "Design",
            isOpen: true,
            joinURL: URL(string: "https://meet.example.test/room")
        )]
        state.people = [CallBreakoutPerson(id: UUID(), name: "Taylor")]
        return state
    }
}

extension CallActivityPresentationTests {
    @Test func cohostJoinRequestsRenderWithoutDenialOrBulkControls() throws {
        var state = CallActivitiesState()
        state.availableActions = ["respondToAdmission"]
        state.waitingParticipants = [
            CallWaitingParticipant(id: UUID(), name: "Maya Okafor", canDeny: false, isJoinRequest: true),
            CallWaitingParticipant(
                id: UUID(),
                name: "Dan Reyes",
                canDeny: false,
                warning: .suspectedBot,
                isJoinRequest: true
            )
        ]
        let entries = try #require(CallRoster.entries([
            CallParticipantDevice(id: UUID(), displayName: "Taylor", role: .cohost)
        ]))
        try renderPeople(state, entries: entries, height: 250, name: "PeopleCohostAdmission")
    }

    @Test func hostControlsRenderInMeetingActivities() async throws {
        var state = sampleState()
        state.hostSettings = CallHostSettings(
            managementEnabled: true, reactionsAllowed: false, chatMessagesAllowed: true,
            screenSharingAllowed: true, microphoneAllowed: true, cameraAllowed: false,
            joiningBeforeHostAllowed: false, waitingRoomEnabled: false,
            meetingAccess: CallMeetingAccess(
                preset: "trusted", availablePresets: ["trusted", "restricted"], joinRequestsAllowed: true
            )
        )
        state.availableActions += [
            "hostManagement", "allowReactions", "allowChatMessages", "allowScreenSharing",
            "allowMicrophone", "allowCamera", "allowJoiningBeforeHost", "setMeetingAccess",
            "allowJoinRequests",
            "endConference"
        ]
        try await render(state, tab: .meeting, name: "HostControls")
    }
}

import ChatKit
import Foundation

/// Deterministic audio state without microphone, network, provider code or timers.
@MainActor
public final class FixtureAudioCallService: AudioCallQuiescing, ExistingAudioCallService,
    ConversationAudioCallService, MeetingLinkAudioCallService, CallInteractionService, CallActivitiesService {
    public let events: AsyncStream<AudioCallEvent>
    public private(set) var currentCall: AudioCallSnapshot?
    public private(set) var recipients: [AudioCallRecipient]
    public private(set) var currentConversationCall: ConversationCallSnapshot?
    private let conversationTargets: Set<Conversation.ID>
    let continuation: AsyncStream<AudioCallEvent>.Continuation
    private var listening = false
    private(set) var participantDevices: [CallParticipantDevice]?
    public private(set) var invitedMembers: [Member.ID] = []
    var activityState = CallActivitiesState()
    var activitySequence: UInt64 = 0
    private var sequence: UInt64 = 0
    private var meetingLinkSequence: UInt64 = 0
    public var nextMeetingAdmission: CallAdmission?
    private var existingCalls: Set<Conversation.ID> = []
    private var existingParticipants: [Conversation.ID: [CallParticipantDevice]] = [:]

    public var canJoinExistingCalls: Bool {
        true
    }

    public func setExistingCallAvailable(_ available: Bool, in id: Conversation.ID) {
        if available {
            existingCalls.insert(id)
        } else {
            existingCalls.remove(id)
            existingParticipants[id] = nil
        }
    }

    /// A script names who is already in a call going on; joining it reports them.
    public func setExistingCallParticipants(_ devices: [CallParticipantDevice], in id: Conversation.ID) {
        guard devices.count <= 256 else { return }
        existingCalls.insert(id)
        existingParticipants[id] = devices
    }

    public func joinExisting(to recipient: AudioCallRecipient, callID: UUID) async throws {
        guard listening, recipients.contains(recipient), currentCall?.phase.isTerminal != false,
              currentConversationCall?.phase.isTerminal != false else {
            throw ChatError.unsupported(capability: "joinExistingAudioCall")
        }
        guard existingCalls.contains(recipient.conversationID) else {
            publish(AudioCallSnapshot(
                id: callID, recipient: recipient, direction: .outgoing, phase: .failed,
                failureMessage: "This call is no longer available."
            ))
            throw ChatError.unknown("This call is no longer available.")
        }
        publish(AudioCallSnapshot(id: callID, recipient: recipient, direction: .outgoing, phase: .connecting))
        setPhase(.connected, callID: callID)
    }

    public var canCallConversations: Bool {
        true
    }

    public func startConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try beginConversation(target, callID: callID, joining: false)
    }

    public func joinConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try beginConversation(target, callID: callID, joining: true)
    }

    private func beginConversation(_ target: ConversationCallTarget, callID: UUID, joining: Bool) throws {
        guard let id = target.conversationID, target.meetingURL == nil, listening,
              conversationTargets.contains(id),
              currentCall?.phase.isTerminal != false,
              currentConversationCall?.phase.isTerminal != false else {
            throw ChatError.unsupported(capability: "conversationCalls")
        }
        currentCall = nil
        var call = ConversationCallSnapshot(id: callID, target: target, phase: .connecting)
        if joining, !existingCalls.contains(id) {
            call.phase = .failed
            call.failureMessage = "This call is no longer available."
            publishConversation(call)
            throw ChatError.unknown("This call is no longer available.")
        }
        publishConversation(call)
        existingCalls.insert(id)
        call.phase = .connected
        publishConversation(call)
        if joining, let devices = existingParticipants[id] {
            setParticipantDevices(devices, callID: callID)
        }
    }

    public func inviteToCall(_ member: Member.ID, callID: UUID) async throws {
        guard (currentCall?.id == callID && currentCall?.phase == .connected) ||
            (currentConversationCall?.id == callID && currentConversationCall?.phase == .connected)
        else { throw CancellationError() }
        invitedMembers.append(member)
    }

    public func setHandRaised(_ raised: Bool, callID: UUID) async throws {
        guard (currentCall?.id == callID && currentCall?.phase == .connected) ||
            (currentConversationCall?.id == callID && currentConversationCall?.phase == .connected)
        else { throw CancellationError() }
        let local = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var devices = (participantDevices ?? []).filter { !$0.isLocal }
        devices.append(CallParticipantDevice(
            id: local,
            displayName: "You",
            isLocal: true,
            handRaised: raised
        ))
        setParticipantDevices(devices, callID: callID)
    }

    public var meetingLinkHosts: Set<String> {
        ["meet.example.test"]
    }

    public var canJoinMeetingLinks: Bool {
        true
    }

    public var canCreateMeetingLinks: Bool {
        true
    }

    public var canPreviewMeetingLinks: Bool {
        true
    }

    public func previewMeetingTitle(at url: URL) async throws -> String? {
        let link = try normalizedMeetingLink(url)
        return meetingLinkHosts.contains(link.host ?? "") ? "Fixture Meeting" : nil
    }

    public func createMeetingLink() async throws -> URL {
        meetingLinkSequence += 1
        return URL(string: "https://meet.example.test/fixture-\(meetingLinkSequence)")!
    }

    public var canConfigureMeetingJoinMedia: Bool {
        true
    }

    public func joinMeeting(at url: URL, callID: UUID) async throws {
        try await joinMeeting(at: url, callID: callID, media: MeetingJoinMedia())
    }

    public func joinMeeting(at url: URL, callID: UUID, media: MeetingJoinMedia) async throws {
        guard !media.cameraEnabled else { throw ChatError.unsupported(capability: "meetingJoinCamera") }
        guard listening, url.scheme == "https", url.user == nil, url.password == nil,
              currentCall?.phase.isTerminal != false,
              currentConversationCall?.phase.isTerminal != false else {
            throw ChatError.unsupported(capability: "meetingLinks")
        }
        currentCall = nil
        let admission = nextMeetingAdmission
        nextMeetingAdmission = nil
        publishConversation(.init(
            id: callID,
            target: .init(meetingURL: url, displayName: "Fixture Meeting"),
            phase: admission == nil ? .connected : .connecting,
            isMuted: media.microphoneMuted, admission: admission
        ))
    }

    public func admitMeetingJoin(callID: UUID) {
        guard var call = currentConversationCall, call.id == callID, call.phase == .connecting,
              call.admission != nil else { return }
        call.admission = nil
        call.phase = .connected
        publishConversation(call)
    }

    private func publishConversation(_ call: ConversationCallSnapshot) {
        if (currentCall?.id ?? currentConversationCall?.id) != call.id {
            participantDevices = nil
            resetActivities()
        }
        currentConversationCall = call
        continuation
            .yield(call.target.meetingURL == nil ? .conversationSnapshot(call) : .meetingSnapshot(call))
        if call.phase == .connected {
            continuation.yield(.interactionChanged(
                callID: call.id,
                state: activityInteraction(url: call.target.meetingURL)
            ))
        }
    }

    public init(world: FixtureWorld = .acme) {
        conversationTargets = Set(world.conversations.filter {
            [.space, .groupDirectMessage].contains($0.kind) && $0.members.contains(world.me)
        }.map(\.id))
        recipients = world.conversations.compactMap { conversation in
            let other = conversation.members.filter { $0 != world.me }
            guard conversation.kind == .directMessage, other.count == 1,
                  conversation.members.contains(world.me),
                  let member = world.member(other[0]), member.kind == .human else { return nil }
            return AudioCallRecipient(
                conversationID: conversation.id, memberID: member.id,
                displayName: member.displayName ?? "Person"
            )
        }
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    public func startListening() async throws {
        listening = true
        continuation.yield(.recipientsChanged(recipients))
        continuation.yield(.listenerChanged(isListening: true))
    }

    public func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        self.recipients = recipients
        if listening {
            continuation.yield(.recipientsChanged(recipients))
        }
    }

    public func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        guard listening, recipients.contains(recipient), currentCall?.phase.isTerminal != false,
              currentConversationCall?.phase.isTerminal != false else {
            throw ChatError.unsupported(capability: "audioCall")
        }
        publish(AudioCallSnapshot(id: callID, recipient: recipient, direction: .outgoing, phase: .ringing))
        setPhase(.connected, callID: callID)
    }

    public func accept(callID: UUID) async throws {
        guard currentCall?.id == callID, currentCall?.phase == .incoming else {
            throw ChatError.unsupported(capability: "audioCall")
        }
        setPhase(.connected, callID: callID)
    }

    public func decline(callID: UUID) async throws {
        setPhase(.declined, callID: callID, endReason: .localEnded)
    }

    public func hangUp(callID: UUID) async throws {
        if var call = currentConversationCall, call.id == callID {
            call.phase = .ended
            call.admission = nil
            call.endReason = .localEnded
            publishConversation(call)
            return
        }
        setPhase(.ended, callID: callID, endReason: .localEnded)
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        if var call = currentConversationCall, call.id == callID, !call.phase.isTerminal {
            call.isMuted = muted
            publishConversation(call)
            return
        }
        guard var call = currentCall, call.id == callID, !call.phase.isTerminal else { return }
        call.isMuted = muted
        publish(call)
    }

    public func setParticipantDevices(_ participants: [CallParticipantDevice]?, callID: UUID) {
        let current = currentConversationCall?.id ?? currentCall?.id
        guard current == callID, participants?.count ?? 0 <= 256 else { return }
        participantDevices = participants
        continuation.yield(.participantsChanged(callID: callID, participants: participants))
    }

    public func beginStopping() {
        listening = false
    }

    public func stop() async {
        listening = false
        currentCall = nil
        currentConversationCall = nil
        participantDevices = nil
        continuation.yield(.recipientsChanged([]))
    }

    public func pauseForRecovery(barrier: UUID) async throws {
        await stop()
        continuation.yield(.listenerBarrier(barrier))
    }

    /// A script/test can produce an incoming call explicitly. UUIDs use a counter.
    @discardableResult
    public func receiveIncoming(from recipient: AudioCallRecipient) -> UUID? {
        guard listening, recipients.contains(recipient),
              currentCall?.phase.isTerminal != false,
              currentConversationCall?.phase.isTerminal != false else { return nil }
        sequence += 1
        let bytes = (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        let id = UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]
        ))
        publish(AudioCallSnapshot(id: id, recipient: recipient, direction: .incoming, phase: .incoming))
        return id
    }

    public func remoteEnded(callID: UUID) {
        setPhase(.ended, callID: callID, endReason: .remoteEnded)
    }

    /// A script/test sets the other person's microphone; nil is unknown.
    public func setRemoteMuted(_ muted: Bool?, callID: UUID) {
        guard var call = currentCall, call.id == callID, !call.phase.isTerminal,
              call.remoteMuted != muted else { return }
        call.remoteMuted = muted
        publish(call)
    }

    public func remoteDeclined(callID: UUID) {
        setPhase(.declined, callID: callID, endReason: .declined)
    }

    private func setPhase(_ phase: AudioCallPhase, callID: UUID, endReason: AudioCallEndReason? = nil) {
        guard var call = currentCall, call.id == callID else { return }
        call.phase = phase
        call.endReason = endReason
        publish(call)
    }

    private func publish(_ call: AudioCallSnapshot) {
        if (currentCall?.id ?? currentConversationCall?.id) != call.id {
            participantDevices = nil
            resetActivities()
        }
        currentConversationCall = nil
        currentCall = call
        continuation.yield(.snapshot(call))
        if call.phase == .connected {
            continuation.yield(.interactionChanged(
                callID: call.id,
                state: activityInteraction(url: URL(string: "https://meet.example.test/fixture"))
            ))
        }
    }
}

extension FixtureAudioCallService {
    public func offerAutomaticHandLowering(_ prompt: CallAutomaticHandLowering, callID: UUID) {
        guard isConnected(callID) else { return }
        activityState.automaticHandLowering = prompt
        if !activityState.availableActions.contains("keepHandRaised") {
            activityState.availableActions.append("keepHandRaised")
        }
        publishFixtureActivities(callID: callID)
    }

    func keepFixtureHandRaised(_ activity: CallActivity) throws {
        guard activity.enabled, activity.participantIDs.isEmpty,
              let prompt = activityState.automaticHandLowering, activity.resourceID == prompt.id
        else { throw CancellationError() }
        activityState.automaticHandLowering = nil
        activityState.availableActions.removeAll { $0 == "keepHandRaised" }
    }

    public func remoteLoweredLocalHand(callID: UUID) {
        guard isConnected(callID), var devices = participantDevices,
              let local = devices
                  .firstIndex(where: { $0.isLocal && !$0.isPresentation && $0.handRaised == true })
        else { return }
        devices[local].handRaised = false
        devices[local].handRaisedAt = nil
        activityState.ownHandLowered = nextActivityID()
        setParticipantDevices(devices, callID: callID)
        publishFixtureActivities(callID: callID)
    }

    func lowerFixtureHands(_ activity: CallActivity, callID: UUID) throws {
        let bulk = activity.action == "lowerAllHands"
        guard activity.enabled, activity.participantIDs.isEmpty,
              bulk == (activity.resourceID == nil), var devices = participantDevices else {
            throw CancellationError()
        }
        let selected = devices.indices.filter {
            !devices[$0]
                .isPresentation && (bulk || (!devices[$0].isLocal && devices[$0].id == activity.resourceID))
        }
        guard bulk || !selected.isEmpty else { throw CancellationError() }
        for index in selected {
            devices[index].handRaised = false
            devices[index].handRaisedAt = nil
        }
        setParticipantDevices(devices, callID: callID)
    }
}

import ChatAPI
import ChatKit
import Foundation

/// A device-scoped API facade. Stopping this observer does not stop service media.
@MainActor
public final class ServiceAudioCallService: ExistingAudioCallService, ConversationAudioCallService,
    MeetingLinkAudioCallService, CallInteractionService, CallActivitiesService {
    public let events: AsyncStream<AudioCallEvent>
    private let sink: AsyncStream<AudioCallEvent>.Continuation
    private let client: AccountClient
    private let account: ConnectedAccountID
    private let revision: ServiceAccountRevision
    private var generation = UUID()
    private var sourceID: UUID?
    private var observer: Task<Void, Never>?
    private var projection = ServiceCallStateProjection()

    public init(account: AccountSummary, client: AccountClient) throws {
        guard let revision = account.revision else { throw ServiceFailure.staleAccount }
        self.account = account.id; self.revision = revision; self.client = client
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func startListening() async throws {
        let epoch = generation
        do {
            let initial = try await read(after: nil, wait: 0)
            try check(epoch)
            try receive(initial)
        } catch {
            try check(epoch)
            reportConnectionFailure()
        }
        guard observer == nil else { return }
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == epoch else { return }
                do {
                    if projection.isConnectionUnavailable {
                        try await Task.sleep(for: .seconds(1))
                        try check(epoch)
                    }
                    let next = try await read(
                        after: projection.version, wait: projection.isConnectionUnavailable ? 0 : 20000
                    )
                    try check(epoch)
                    try receive(next)
                } catch {
                    guard !Task.isCancelled, generation == epoch else { return }
                    reportConnectionFailure()
                }
            }
        }
    }

    /// Provider-verified recipients arrive from the service; client hints grant nothing.
    public func updateRecipients(_: [AudioCallRecipient]) async {}

    public func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await control(.init(action: "start", callID: callID, recipient: recipient))
    }

    public var canJoinExistingCalls: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsExistingJoin == true
    }

    public func joinExisting(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await control(.init(action: "join", callID: callID, recipient: recipient))
    }

    public var canCallConversations: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsConversationCalls == true
    }

    public func startConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await controlConversation("start", target: target, id: callID)
    }

    public func joinConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await controlConversation("join", target: target, id: callID)
    }

    private func controlConversation(
        _ action: String,
        target: ConversationCallTarget,
        id: UUID
    ) async throws {
        let epoch = generation
        if sourceID == nil {
            try await receive(read(after: nil, wait: 0))
        }
        try check(epoch)
        guard let sourceID else { throw ServiceFailure.staleCallSource }
        guard let conversationID = target.conversationID,
              target.meetingURL == nil else { throw ServiceFailure.invalidRequest }
        let request = ControlConversationCall(
            action: action, conversationID: conversationID, callID: id, sourceID: sourceID
        )
        let result = try await client.call(request, account: account, revision: revision)
        try check(epoch)
        try receive(result)
    }

    public var meetingLinkHosts: Set<String> {
        guard canJoinMeetingLinks else { return [] }
        let hosts = (projection.currentState?.meetingLinkHosts ?? []).prefix(8)
        return Set(hosts.filter { !$0.isEmpty && $0.utf8.count <= 253 })
    }

    public var canJoinMeetingLinks: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsMeetingLinks == true
    }

    public var canCreateMeetingLinks: Bool {
        !projection.isConnectionUnavailable && projection.currentState?.supportsMeetingLinkCreation == true
    }

    public var canPreviewMeetingLinks: Bool {
        canJoinMeetingLinks && projection.currentState?.supportsMeetingLinkPreview == true
    }

    public func previewMeetingTitle(at url: URL) async throws -> String? {
        try await previewMeetingTitle(at: url, reference: nil, calendarOnly: false)
    }

    public func previewMeetingTitle(
        at url: URL,
        reference: Date?,
        calendarOnly: Bool
    ) async throws -> String? {
        let epoch = generation
        guard canPreviewMeetingLinks, let sourceID else { throw ServiceFailure.unsupportedOperation }
        let title = try await client.call(
            PreviewMeetingLink(
                url: url,
                sourceID: sourceID,
                reference: reference,
                calendarOnly: calendarOnly ? true : nil
            ),
            account: account, revision: revision, timeout: 12
        )
        try check(epoch)
        guard sourceID == self.sourceID else { throw ServiceFailure.staleCallSource }
        return title
    }

    public func createMeetingLink() async throws -> URL {
        let epoch = generation
        guard canCreateMeetingLinks, let sourceID else { throw ServiceFailure.unsupportedOperation }
        let url = try await client.call(
            CreateMeetingLink(requestID: UUID(), sourceID: sourceID),
            account: account,
            revision: revision
        )
        try check(epoch)
        guard sourceID == self.sourceID else { throw ServiceFailure.staleCallSource }
        return url
    }

    public var canConfigureMeetingJoinMedia: Bool {
        canJoinMeetingLinks && projection.currentState?.supportsMeetingJoinMedia == true
    }

    public func joinMeeting(at url: URL, callID: UUID) async throws {
        try await joinMeeting(at: url, callID: callID, media: MeetingJoinMedia())
    }

    public func joinMeeting(at url: URL, callID: UUID, media: MeetingJoinMedia) async throws {
        let epoch = generation
        if sourceID == nil {
            try await receive(read(after: nil, wait: 0))
        }
        try check(epoch)
        guard canJoinMeetingLinks, let sourceID else { throw ServiceFailure.unsupportedOperation }
        let options = media == MeetingJoinMedia() ? nil : media
        guard options == nil || canConfigureMeetingJoinMedia
        else { throw ServiceFailure.unsupportedOperation }
        let result = try await client.call(
            JoinMeetingCall(url: url, callID: callID, sourceID: sourceID, media: options),
            account: account,
            revision: revision
        )
        try check(epoch)
        try receive(result)
    }

    public func inviteToCall(_ member: Member.ID, callID: UUID) async throws {
        let epoch = generation
        guard let sourceID else { throw ServiceFailure.staleCallSource }
        let result = try await client.call(
            InviteCallParticipant(callID: callID, sourceID: sourceID, memberID: member),
            account: account,
            revision: revision
        )
        try check(epoch)
        try receive(result)
    }

    public func setHandRaised(_ raised: Bool, callID: UUID) async throws {
        let epoch = generation
        guard let sourceID else { throw ServiceFailure.staleCallSource }
        let result = try await client.call(
            ControlCallInteraction(callID: callID, sourceID: sourceID, raised: raised),
            account: account,
            revision: revision
        )
        try check(epoch)
        try receive(result)
    }

    public func performCallActivity(_ activity: CallActivity, callID: UUID) async throws {
        let epoch = generation
        guard let sourceID else { throw ServiceFailure.staleCallSource }
        let result = try await client.call(
            PerformCallActivity(callID: callID, sourceID: sourceID, activity: activity),
            account: account,
            revision: revision
        )
        try check(epoch)
        try receive(result)
    }

    public func accept(callID: UUID) async throws {
        try await control(.init(action: "accept", callID: callID))
    }

    public func decline(callID: UUID) async throws {
        try await control(.init(action: "decline", callID: callID))
    }

    public func hangUp(callID: UUID) async throws {
        try await control(.init(action: "hangUp", callID: callID))
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        try await control(.init(action: "mute", callID: callID, muted: muted))
    }

    /// Explicit native authentication recovery, permitted only while idle.
    public func restartListener() async throws {
        try await control(.init(action: "restart"))
    }

    public func prepareRecovery() async throws {
        await stop()
        try await control(.init(action: "pause"))
    }

    public func finishRecovery() async throws {
        try await restartListener()
    }

    public func stop() async {
        generation = UUID()
        let pending = observer
        observer = nil
        pending?.cancel()
        await pending?.value
        projection = ServiceCallStateProjection()
        sourceID = nil
    }

    private func read(after version: String?, wait: Int) async throws -> ServiceCallState {
        try await client.call(
            ReadCallState(after: version, waitMilliseconds: wait), account: account, revision: revision,
            timeout: 25
        )
    }

    private func control(_ request: ControlCall) async throws {
        let epoch = generation
        if sourceID == nil {
            try await receive(read(after: nil, wait: 0))
        }
        try check(epoch)
        let scoped = ControlCall(
            action: request.action,
            callID: request.callID,
            recipient: request.recipient,
            muted: request.muted,
            sourceID: sourceID
        )
        let result = try await client.call(scoped, account: account, revision: revision)
        try check(epoch)
        try receive(result)
    }

    private func receive(_ state: ServiceCallState) throws {
        let events = try projection.accept(state)
        sourceID = projection.currentState?.sourceID
        for event in events {
            sink.yield(event)
        }
    }

    private func reportConnectionFailure() {
        for event in projection.connectionFailed() {
            sink.yield(event)
        }
    }

    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
}

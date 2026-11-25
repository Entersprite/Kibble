import ChatKit
import Foundation

struct MeetingPreparation {
    let id: UUID
    let url: URL
    var title: String?
    var media = MeetingJoinMedia()
}

public extension AudioCallController {
    var meetingLinkHosts: Set<String> {
        guard canJoinMeetingLinks else { return [] }
        return supportedMeetingLinkHosts
    }

    var canJoinMeetingLinks: Bool {
        isAvailable && !isRecovering && supportsMeetingLinks
    }

    var canCreateMeetingLinks: Bool {
        isAvailable && !isRecovering && supportsMeetingLinkCreation
    }

    func createMeetingLink() async throws -> URL {
        guard canCreateMeetingLinks, let links = service as? any MeetingLinkAudioCallService else {
            throw ChatError.unsupported(capability: "meetingLinkCreation")
        }
        let current = generation
        let url = try await links.createMeetingLink()
        try Task.checkCancellation()
        guard generation == current, canCreateMeetingLinks else { throw CancellationError() }
        return url
    }

    func waitingRoomReturnLink(after id: UUID) -> URL? {
        guard canJoinMeetingLinks, !isEnding, let call, call.id == id, call.phase == .ended,
              call.endReason == .sentToWaitingRoom, call.failureMessage == nil,
              let links = service as? any MeetingLinkAudioCallService else { return nil }
        var candidate = observedMeetingLink?.callID == id ? observedMeetingLink?.url : nil
        if case let .conversation(target) = call.target {
            candidate = candidate ?? target.meetingURL
        }
        guard let candidate, let url = try? links.normalizedMeetingLink(candidate),
              let host = url.host?.lowercased(), meetingLinkHosts.contains(host) else { return nil }
        return url
    }

    func returnToMeeting(after id: UUID) {
        guard let url = waitingRoomReturnLink(after: id) else { return }
        joinMeeting(at: url)
    }

    var meetingPreparationID: UUID? {
        meetingPreparation?.id
    }

    func meetingJoinMedia(for id: UUID) -> MeetingJoinMedia? {
        guard supportsMeetingJoinMedia, meetingPreparation?.id == id else { return nil }
        return meetingPreparation?.media
    }

    func setMeetingJoinMedia(_ media: MeetingJoinMedia, for id: UUID) {
        guard meetingJoinMedia(for: id) != nil else { return }
        meetingPreparation?.media = media
    }

    /// Window projection only. A preview holds no call lease or media.
    var callWindowSession: AudioCallSession? {
        guard let preparation = meetingPreparation else { return call }
        return meetingSession(id: preparation.id, url: preparation.url, title: preparation.title)
    }

    @discardableResult
    func prepareMeeting(at url: URL) -> UUID? {
        guard canJoinMeetingLinks, url.scheme == "https", url.user == nil, url.password == nil,
              url.absoluteString.utf8.count <= 2048,
              let host = url.host?.lowercased(), meetingLinkHosts.contains(host) else { return nil }
        if raiseCurrentCall() {
            return nil
        }
        if let current = meetingPreparation, current.url == url {
            windowRequests += 1
            return current.id
        }
        clearMeetingPreparation()
        let id = UUID()
        call = nil
        meetingPreparation = MeetingPreparation(id: id, url: url)
        windowRequests += 1
        readMeetingPreview(id: id, url: url)
        return id
    }

    func cancelMeetingPreparation(_ id: UUID) {
        guard meetingPreparation?.id == id else { return }
        clearMeetingPreparation()
    }

    internal func clearMeetingPreparation() {
        meetingPreviewTask?.cancel()
        meetingPreviewTask = nil
        meetingPreparation = nil
    }

    private func readMeetingPreview(id: UUID, url: URL) {
        guard let links = service as? any MeetingLinkAudioCallService, links.canPreviewMeetingLinks else {
            return
        }
        let scope = generation
        meetingPreviewTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let title = try? await links.previewMeetingTitle(at: url)
            guard let self, !Task.isCancelled, generation == scope, meetingPreparation?.id == id else {
                return
            }
            meetingPreviewTask = nil
            if let title, links.canPreviewMeetingLinks, canJoinMeetingLinks {
                meetingPreparation?.title = title
            }
        }
    }

    func joinPreparedMeeting(_ id: UUID) {
        guard let preparation = meetingPreparation, preparation.id == id else { return }
        guard canJoinMeetingLinks, !raiseCurrentCall(),
              let links = service as? any MeetingLinkAudioCallService else {
            cancelMeetingPreparation(id)
            return
        }
        beginMeeting(
            at: preparation.url, id: id, links: links, title: preparation.title, media: preparation.media
        )
    }

    func dismissCallWindow(_ id: UUID) {
        cancelMeetingPreparation(id)
        if call?.id == id {
            windowClosed()
        }
    }

    @discardableResult
    func joinMeeting(at url: URL) -> UUID? {
        joinMeeting(at: url, media: MeetingJoinMedia())
    }

    @discardableResult
    internal func joinMeeting(at url: URL, media: MeetingJoinMedia) -> UUID? {
        if raiseCurrentCall() {
            return nil
        }
        guard canJoinMeetingLinks, media == MeetingJoinMedia() || supportsMeetingJoinMedia,
              let links = service as? any MeetingLinkAudioCallService else { return nil }
        return beginMeeting(at: url, id: UUID(), links: links, media: media)
    }

    @discardableResult
    private func beginMeeting(
        at url: URL, id: UUID, links: any MeetingLinkAudioCallService, title: String? = nil,
        media: MeetingJoinMedia = MeetingJoinMedia()
    ) -> UUID {
        begin(meetingSession(id: id, url: url, title: title, muted: media.microphoneMuted)) { id in
            try await links.joinMeeting(at: url, callID: id, media: media)
        }
    }

    private func meetingSession(
        id: UUID, url: URL, title: String?, muted: Bool = false
    ) -> AudioCallSession {
        AudioCallSession(.init(
            id: id, target: ConversationCallTarget(meetingURL: url, displayName: title ?? "Meeting"),
            phase: .connecting, isMuted: muted
        ), isJoining: true)
    }
}

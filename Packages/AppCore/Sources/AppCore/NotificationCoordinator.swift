import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// Turns a session's announcements into notifications, and notification
/// clicks back into actions on that session.
///
/// Lives for the process, owned by `AppEnvironment`; sessions come and go
/// underneath it through `attach(_:announcements:)` and `detach()`. The
/// decision itself is `NotificationPolicy`'s, in `SyncEngine`, so that a future
/// server gating push runs the same rule; what is here is the part only a
/// client has - what is on screen, what things are called, and where a click
/// should go.
@MainActor
final class NotificationCoordinator {
    private let delivery: any NotificationDelivering
    /// Asks the host to bring the main window forward. Set by
    /// `AppEnvironment` once it can capture itself.
    var onShowWindow: (@MainActor () -> Void)?
    /// Resolves a conversation's rule. Set by `AppEnvironment` once its
    /// settings model exists; `nil` (in a test with no host wiring) falls
    /// back to `.builtIn`.
    var resolveRule: (@MainActor (Conversation) -> ResolvedRule)?

    private var model: ChatSessionModel?
    private var announcementsTask: Task<Void, Never>?
    private var responsesTask: Task<Void, Never>?
    private var requestedAuthorization = false

    /// A click that arrived before any session existed - the click that
    /// launched the app. Only the latest is kept; replayed by
    /// `replayPending()` once the session has started.
    private var pending: NotificationResponse?

    /// Message ids announced this session, oldest first, capped at
    /// `recentLimit`. Backs `NotificationPolicy.Reason.alreadyAnnounced`.
    private var recent: [Message.ID] = []
    private var recentSet: Set<Message.ID> = []
    static let recentLimit = 500

    init(delivery: any NotificationDelivering) {
        self.delivery = delivery
    }

    /// Starts listening for clicks. Once per process; the delivery's response
    /// stream has exactly one consumer, and this is it.
    func start() {
        guard responsesTask == nil else { return }
        let responses = delivery.responses
        responsesTask = Task { [weak self] in
            for await response in responses {
                self?.handle(response)
            }
        }
    }

    /// Starts hearing `model`'s announcements. Does **not** replay a pending
    /// click - see `replayPending()`.
    func attach(_ model: ChatSessionModel, announcements: AsyncStream<SyncAnnouncement>) {
        announcementsTask?.cancel()
        self.model = model
        announcementsTask = Task { [weak self] in
            for await announcement in announcements {
                await self?.handle(announcement)
            }
        }
    }

    /// Acts on the click that arrived before any session existed, once the
    /// attached session has started.
    ///
    /// **Separate from `attach`, because the two happen at different times.**
    /// `AppEnvironment` attaches *before* `model.start()`, so arrivals during
    /// connect are heard; replaying there submitted a "Mark as Read" that
    /// launched the app before `connect()` had finished, and it was lost. So
    /// `AppEnvironment.start()` calls this only once `model.start()` has
    /// succeeded.
    func replayPending() {
        guard model != nil, let pending else { return }
        self.pending = nil
        handle(pending)
    }

    /// The session is ending. Stops listening, drops a click still waiting to
    /// be replayed, and clears Notification Center, because the next session
    /// may be a different account.
    func detach() async {
        announcementsTask?.cancel()
        announcementsTask = nil
        model = nil
        pending = nil
        recent = []
        recentSet = []
        await delivery.withdrawAll()
    }

    /// Once per process, the first time a session is running - not at launch,
    /// so the permission prompt does not compete with sign-in.
    func requestAuthorizationOnce() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        Task { [delivery] in
            await delivery.requestAuthorization()
        }
    }

    func handle(_ announcement: SyncAnnouncement) async {
        switch announcement {
        case let .arrived(message):
            guard let model else { return }
            let conversation = model.conversations.first { $0.id == message.conversationID }
            // Review Focus 3: an unlisted conversation resolves through Other.
            let rule = resolveRule?(conversation ?? Conversation(
                id: message.conversationID,
                kind: .unknown("")
            ))
                ?? .builtIn
            // `isActive` is the viewing gate - frontmost *and* the window on
            // screen - which `AppEnvironment` computes and pushes into the
            // model. Selected-but-not-visible is not on screen.
            let decision = NotificationPolicy.decide(
                message,
                rule: rule,
                me: model.me,
                viewing: model.isActive ? model.selected : nil,
                alreadyAnnounced: recentSet.contains(message.id)
            )
            guard case let .post(presentation) = decision else { return }
            remember(message.id)
            await delivery.post(Self.notification(
                for: message, in: conversation, directory: model.directory, me: model.me,
                presentation: presentation,
                // "Mark as Read" would be refused at `SyncEngine.submit` here.
                offersMarkRead: rule.readReceipts
            ))
        case let .read(conversation, upTo):
            await delivery.withdraw(in: conversation, coveredBy: upTo)
        }
    }

    func handle(_ response: NotificationResponse) {
        guard let model else {
            pending = response
            if case .open = response {
                onShowWindow?()
            }
            return
        }
        switch response {
        case let .open(conversation):
            model.select(conversation)
            onShowWindow?()
        case let .markRead(conversation):
            model.markRead(conversation)
        }
    }

    /// What a notification for `message` says. Pure, so the wording is tested
    /// without a notification center.
    ///
    /// - The title is the conversation's, exactly as the sidebar shows it. With
    ///   no conversation on record yet, it is the sender.
    /// - The subtitle names the sender, except where the title already does -
    ///   a one-to-one conversation, human or app - or where nobody has named
    ///   the sender yet, since a raw user id in a banner reads as a bug.
    /// - An empty body (an attachment-only message, today) says so rather than
    ///   posting a blank banner.
    static func notification(
        for message: Message,
        in conversation: Conversation?,
        directory: [Member.ID: Member],
        me: Member.ID?,
        presentation: NotificationPolicy.Presentation = .init(
            isPassive: false,
            playsSound: true,
            showsPreview: true
        ),
        offersMarkRead: Bool = true
    ) -> MessageNotification {
        let senderName = Display.name(of: message.sender, in: directory)
        let title = conversation.map { Display.title(of: $0, directory: directory, me: me) } ?? senderName
        let isOneToOne = switch conversation?.kind {
        case .directMessage, .appDirectMessage, nil: true
        default: false
        }
        let subtitle = !isOneToOne && Display.hasName(of: message.sender, in: directory)
            ? senderName
            : nil
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return MessageNotification(
            id: message.id.rawValue,
            conversationID: message.conversationID,
            title: title,
            subtitle: subtitle,
            body: presentation.showsPreview && !text.isEmpty ? text : "New message",
            createdAt: message.createdAt,
            isPassive: presentation.isPassive,
            playsSound: presentation.playsSound,
            offersMarkRead: offersMarkRead
        )
    }

    private func remember(_ id: Message.ID) {
        recent.append(id)
        recentSet.insert(id)
        if recent.count > Self.recentLimit {
            recentSet.remove(recent.removeFirst())
        }
    }
}

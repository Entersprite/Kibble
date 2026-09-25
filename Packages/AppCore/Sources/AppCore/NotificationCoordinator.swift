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

    /// Clicks held until a session has started: the one that launched the
    /// app, and any while the attached session is still connecting. Every
    /// one, in order, replayed by `replayPending(for:)`. Keeping only the
    /// latest lost the first of two - a "Mark as Read" that launched the app,
    /// then another during connect, marked only the second, and pressing an
    /// action had already removed the first banner.
    private var pending: [NotificationResponse] = []

    /// Whether a click with no session is the one that launched the app, and
    /// so worth holding. `true` until the first `detach()`, and never again:
    /// after a session has ended, a click with no session is a banner that
    /// raced the withdraw, and the next sign-in may be another account.
    private var holdsLaunchingClick = true

    /// Whether the attached session has started, and so can act on a click.
    /// Cleared by `attach`, set by `replayPending(for:)`: `AppEnvironment`
    /// attaches before `model.start()`, and a "Mark as Read" acted on while
    /// `connect()` was still running could be submitted before it finished,
    /// and be lost.
    private var sessionStarted = false

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
    /// click - see `replayPending(for:)`.
    func attach(_ model: ChatSessionModel, announcements: AsyncStream<SyncAnnouncement>) {
        announcementsTask?.cancel()
        self.model = model
        sessionStarted = false
        announcementsTask = Task { [weak self] in
            for await announcement in announcements {
                await self?.handle(announcement)
            }
        }
    }

    /// Marks `model` started, and acts on the clicks held until then - the
    /// one that launched the app, and any during connect.
    ///
    /// **Names the session it is for**, and does nothing unless that is the
    /// one attached: a replay arriving for a session since replaced would
    /// otherwise start the newer one while its own connect is still running.
    /// That also covers a call with nothing attached, where a held `.open`
    /// would go round `handle(_:)` again and ask for the window twice.
    ///
    /// **Separate from `attach`, because the two happen at different times.**
    /// `AppEnvironment` attaches *before* `model.start()`, so arrivals during
    /// connect are heard; replaying there submitted a "Mark as Read" that
    /// launched the app before `connect()` had finished, and it was lost. So
    /// `AppEnvironment.start()` calls this only once `model.start()` has
    /// succeeded.
    func replayPending(for model: ChatSessionModel) {
        guard self.model === model else { return }
        sessionStarted = true
        let held = pending
        pending = []
        for response in held {
            handle(response)
        }
    }

    /// The session is ending. Stops listening, drops a click still waiting to
    /// be replayed, and clears Notification Center, because the next session
    /// may be a different account.
    ///
    /// **Also stops holding clicks for good** (`holdsLaunchingClick`), and
    /// that is cleared before the first suspension: a click during the waits
    /// below, or anywhere in sign-in afterwards, used to be held and replayed
    /// into the next sign-in. `AppEnvironment` calls this on every way into
    /// sign-in, including a launch that never built a session, so a previous
    /// process's banners are withdrawn too.
    ///
    /// **Waits for the announcements task before withdrawing.** Cancelling
    /// does not stop a `post` already handed to the delivery, and one that
    /// landed after `withdrawAll()` would leave this account's message text
    /// in Notification Center for the next one to see. `model` is released
    /// first, so a click during the wait is held rather than acted on, and
    /// then dropped with any other.
    ///
    /// **So sign-out waits on the notification center**, the reverse of
    /// `ChatSessionModel.stop()`, which cancels its history and mark tasks
    /// rather than joining them so that a hung request cannot hang sign-out.
    /// Here the wait joins a `post` already handed to the delivery - for
    /// `UserNotificationDelivery`, an `add` to `UNUserNotificationCenter` -
    /// (`UserNotificationDelivery.withdrawAll()` is synchronous and cannot).
    /// A `usernotificationsd` that never answered an `add` would hang
    /// sign-out until relaunch `[Verify]`: nothing has seen it happen. The trade is deliberate: not waiting
    /// is what left the
    /// previous account's message text in Notification Center.
    func detach() async {
        // First, before any suspension: a click during the waits below must
        // not be held for the next session.
        holdsLaunchingClick = false
        let announcements = announcementsTask
        announcements?.cancel()
        announcementsTask = nil
        model = nil
        await announcements?.value
        pending = []
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
        // Held until a session has started: the launching click, or one
        // while the attached session is still connecting.
        guard let model, sessionStarted else {
            if model != nil || holdsLaunchingClick {
                pending.append(response)
            }
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

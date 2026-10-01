import ChatKit
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// A notification center that records instead of showing anything.
actor FakeNotificationDelivery: NotificationDelivering {
    struct Withdrawal: Equatable {
        let conversation: Conversation.ID
        let position: Date
    }

    /// Posts and withdraw-alls in the order they landed.
    enum Landed: Equatable {
        case posted(String)
        case withdrewAll
    }

    private(set) var posted: [MessageNotification] = []
    private(set) var withdrawals: [Withdrawal] = []
    private(set) var withdrawAllCount = 0
    private(set) var authorizationRequests = 0
    private(set) var landed: [Landed] = []
    /// Posts entered, including any still held by `holdPosts()`.
    private(set) var postsStarted = 0
    private var holdsPosts = false
    private var heldPosts: [CheckedContinuation<Void, Never>] = []
    /// Withdraw-alls entered, including one still held by `holdWithdrawAll()`.
    private(set) var withdrawAllsStarted = 0
    private var holdsWithdrawAll = false
    private var heldWithdrawAll: CheckedContinuation<Void, Never>?

    nonisolated let responses: AsyncStream<NotificationResponse>
    nonisolated let respond: AsyncStream<NotificationResponse>.Continuation

    init() {
        (responses, respond) = AsyncStream.makeStream()
    }

    func requestAuthorization() {
        authorizationRequests += 1
    }

    /// Makes every `post` wait for `releasePosts()` - a post in flight.
    func holdPosts() {
        holdsPosts = true
    }

    func releasePosts() {
        holdsPosts = false
        for post in heldPosts {
            post.resume()
        }
        heldPosts = []
    }

    func post(_ notification: MessageNotification) async {
        postsStarted += 1
        if holdsPosts {
            await withCheckedContinuation { heldPosts.append($0) }
        }
        posted.append(notification)
        landed.append(.posted(notification.id))
    }

    func withdraw(in conversation: Conversation.ID, coveredBy position: Date) {
        withdrawals.append(Withdrawal(conversation: conversation, position: position))
    }

    /// Makes the next `withdrawAll` wait for `releaseWithdrawAll()` - the
    /// last suspension in `NotificationCoordinator.detach()`.
    func holdWithdrawAll() {
        holdsWithdrawAll = true
    }

    func releaseWithdrawAll() {
        holdsWithdrawAll = false
        heldWithdrawAll?.resume()
        heldWithdrawAll = nil
    }

    func withdrawAll() async {
        withdrawAllsStarted += 1
        if holdsWithdrawAll {
            await withCheckedContinuation { heldWithdrawAll = $0 }
        }
        withdrawAllCount += 1
        landed.append(.withdrewAll)
    }
}

@MainActor
struct NotificationCoordinatorTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let dm = Conversation.ID("dm/1")
    private let space = Conversation.ID("space/1")

    private func message(
        _ id: String = "m:1", from sender: Member.ID, in conversation: Conversation.ID, text: String = "hello"
    ) -> Message {
        Message(
            id: Message.ID(id),
            conversationID: conversation,
            threadID: MessageThread.ID("topic:1"),
            sender: sender,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - What a notification says

    @Test func aOneToOneConversationIsTitledAndNotSubtitled() {
        let conversation = Conversation(id: dm, kind: .directMessage, members: [me.id, alice.id])
        let notification = NotificationCoordinator.notification(
            for: message(from: alice.id, in: dm), in: conversation,
            directory: [me.id: me, alice.id: alice], me: me.id
        )
        #expect(notification.title == "Alice")
        #expect(notification.subtitle == nil)
        #expect(notification.body == "hello")
        #expect(notification.conversationID == dm)
    }

    @Test func aSpaceNamesItsSender() {
        let conversation = Conversation(id: space, kind: .space, title: "Design")
        let notification = NotificationCoordinator.notification(
            for: message(from: alice.id, in: space), in: conversation,
            directory: [alice.id: alice], me: me.id
        )
        #expect(notification.title == "Design")
        #expect(notification.subtitle == "Alice")
    }

    /// A raw user id in a banner reads as a bug.
    @Test func anUnnamedSenderIsLeftOutRatherThanShownAsAnID() {
        let conversation = Conversation(id: space, kind: .space, title: "Design")
        let notification = NotificationCoordinator.notification(
            for: message(from: alice.id, in: space), in: conversation, directory: [:], me: me.id
        )
        #expect(notification.subtitle == nil)
    }

    @Test func anEmptyMessageSaysSoAndAnUnknownConversationIsTitledBySender() {
        let notification = NotificationCoordinator.notification(
            for: message(from: alice.id, in: space, text: "  "), in: nil,
            directory: [alice.id: alice], me: me.id
        )
        #expect(notification.body == "New message")
        #expect(notification.title == "Alice")
    }

    private func withAttachments(_ attachments: [ChatKit.Attachment], text: String = "") -> Message {
        var message = message(from: alice.id, in: space, text: text)
        message.attachments = attachments
        return message
    }

    private let png = ChatKit.Attachment(id: "a", name: "a.png", contentType: "image/png")
    private let pdf = ChatKit.Attachment(id: "b", name: "b.pdf", contentType: "application/pdf")

    @Test func anImageOnlyMessageSaysItSentAnImage() {
        let notification = NotificationCoordinator.notification(
            for: withAttachments([pdf, png]), in: nil, directory: [alice.id: alice], me: me.id
        )
        #expect(notification.body == "Sent an image")
    }

    @Test func aFileOnlyMessageSaysItSentAFile() {
        let notification = NotificationCoordinator.notification(
            for: withAttachments([pdf]), in: nil, directory: [alice.id: alice], me: me.id
        )
        #expect(notification.body == "Sent a file")
    }

    @Test func textBesideAnAttachmentIsStillTheBody() {
        let notification = NotificationCoordinator.notification(
            for: withAttachments([png], text: "look"), in: nil, directory: [alice.id: alice], me: me.id
        )
        #expect(notification.body == "look")
    }

    /// A hidden preview hides what kind of thing was sent, too.
    @Test func aHiddenPreviewSaysOnlyNewMessage() {
        let notification = NotificationCoordinator.notification(
            for: withAttachments([png]), in: nil, directory: [alice.id: alice], me: me.id,
            presentation: .init(isPassive: false, playsSound: true, showsPreview: false)
        )
        #expect(notification.body == "New message")
    }

    // MARK: - The viewing gate

    /// The defect this slice found: frontmost with no window is not viewing,
    /// so auto-mark-read must stop and banners must resume.
    @Test func closingOrMinimisingTheWindowStopsViewing() async throws {
        let environment = try AppEnvironment(services: FakeLaunchServices())
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        environment.setActive(true)
        #expect(model.isActive)

        environment.setWindowOpen(false)
        #expect(!model.isActive)
        environment.setWindowOpen(true)
        #expect(model.isActive)

        environment.setWindowMinimized(true)
        #expect(!model.isActive)
        environment.setWindowMinimized(false)
        #expect(model.isActive)

        environment.setActive(false)
        #expect(!model.isActive)
    }

    /// A window closed while minimised reports no deminiaturise, so the one
    /// that next appears must clear the flag - or the gate stays off for good.
    @Test func aWindowThatAppearsAfterOneWasClosedMinimisedIsViewed() async throws {
        let environment = try AppEnvironment(services: FakeLaunchServices())
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        environment.setActive(true)
        environment.setWindowMinimized(true)
        environment.setWindowOpen(false)
        environment.setWindowOpen(true)
        #expect(model.isActive)
    }

    /// The banner half of the gate: the conversation on screen is not
    /// announced, and the same conversation behind a closed window is.
    ///
    /// The Design arrival is a sentinel. Announcements are handled one at a
    /// time, in order, so once it is posted the DM arrival before it has
    /// certainly been decided - which is what makes "not posted" observable
    /// without waiting out a timeout.
    @Test func theConversationOnScreenIsNotAnnouncedUntilTheWindowCloses() async throws {
        let services = try FakeLaunchServices()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([
            Conversation(id: dm, kind: .directMessage, members: [me.id, alice.id]),
            Conversation(id: space, kind: .space, title: "Design")
        ]))
        #expect(await eventually { model.me == me.id && model.conversations.count == 2 })
        model.select(dm)
        environment.setActive(true)
        #expect(model.isActive)

        services.backend.emit(.messageReceived(message("m:on-screen", from: alice.id, in: dm)))
        services.backend.emit(.messageReceived(message("m:sentinel", from: alice.id, in: space)))
        #expect(await eventually { await delivery.posted.count == 1 })
        #expect(await delivery.posted.map(\.id) == ["m:sentinel"])

        environment.setWindowOpen(false)
        services.backend.emit(.messageReceived(message("m:window-closed", from: alice.id, in: dm)))
        #expect(await eventually { await delivery.posted.count == 2 })
        #expect(await delivery.posted.map(\.id) == ["m:sentinel", "m:window-closed"])
    }

    @Test func aWindowClosedBeforeTheSessionExistsIsAppliedOnceItDoes() async throws {
        let environment = try AppEnvironment(services: FakeLaunchServices())
        environment.setWindowOpen(false)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(!model.isActive)
    }

    // MARK: - End to end, through a fake notification center

    @Test func anArrivalIsPostedAReadWithdrawsAndSignOutClearsEverything() async throws {
        let services = try FakeLaunchServices()
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(await eventually { await delivery.authorizationRequests == 1 })

        services.backend.emit(.selfIdentified(me))
        #expect(await eventually { model.me == me.id })

        services.backend.emit(.messageReceived(message(from: alice.id, in: dm)))
        #expect(await eventually { await delivery.posted.count == 1 })
        #expect(await delivery.posted.first?.id == "m:1")

        // Own messages - the channel's echo of a send - are not announced.
        services.backend.emit(.messageReceived(message("m:2", from: me.id, in: dm)))
        let readAt = Date(timeIntervalSince1970: 1_700_000_001)
        services.backend.emit(.readStateChanged(conversationID: dm, lastReadAt: readAt, unread: 0))
        #expect(await eventually { await !delivery.withdrawals.isEmpty })
        #expect(await delivery.withdrawals == [.init(conversation: dm, position: readAt)])
        #expect(await delivery.posted.count == 1)

        await environment.signOut()
        #expect(await delivery.withdrawAllCount == 1)
    }

    // MARK: - Clicks

    @Test func clickingANotificationOpensItsConversationAndAsksForTheWindow() async throws {
        let delivery = FakeNotificationDelivery()
        let environment = try AppEnvironment(services: FakeLaunchServices(), notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }

        delivery.respond.yield(.open(dm))
        #expect(await eventually { model.selected == dm })
        #expect(environment.windowRequests == 1)
    }

    /// The click that launched the app arrives before any session exists.
    @Test func aClickBeforeTheSessionExistsIsReplayedOnceItDoes() async throws {
        let delivery = FakeNotificationDelivery()
        let environment = try AppEnvironment(services: FakeLaunchServices(), notifications: delivery)
        delivery.respond.yield(.open(dm))
        #expect(await eventually { environment.windowRequests == 1 })

        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(model.selected == dm)
    }
}

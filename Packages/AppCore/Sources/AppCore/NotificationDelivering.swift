import ChatKit
import Foundation

/// Where notifications actually go - the operating system's notification
/// center, behind a seam.
///
/// **The seam is the point.** `UNUserNotificationCenter.current()` needs a real
/// bundle and crashes under a test runner, so nothing in this package may reach
/// it: `MacHost`'s `UserNotificationDelivery` is the one conformance that does,
/// and every test uses a fake. The same trick `HTTPTransport` plays one layer
/// down. A future iOS host supplies its own conformance; nothing above this
/// protocol changes.
public protocol NotificationDelivering: Sendable {
    /// Asks the user for permission once. A refusal is not an error - posting
    /// simply does nothing afterwards - so this does not throw.
    func requestAuthorization() async

    func post(_ notification: MessageNotification) async

    /// Removes delivered notifications for messages in `conversation` that
    /// `position` covers - `createdAt < position`, `findings.md` §36's strict
    /// boundary - and leaves newer ones alone.
    func withdraw(in conversation: Conversation.ID, coveredBy position: Date) async

    /// Removes everything this app has delivered. Called on sign-out, so a
    /// previous account's message text does not sit in Notification Center.
    func withdrawAll() async

    /// What the user did with a notification. **Single consumer**, for the
    /// life of the process: the app's `NotificationCoordinator`.
    var responses: AsyncStream<NotificationResponse> { get }
}

/// One message, ready to show.
public struct MessageNotification: Sendable, Equatable {
    /// The message's own id, so re-posting the same message replaces rather
    /// than duplicates.
    public var id: String
    public var conversationID: Conversation.ID
    public var title: String
    /// Who sent it, when the title does not already say - `nil` for a
    /// one-to-one conversation, and for a sender nobody has named yet.
    public var subtitle: String?
    public var body: String
    /// Carried so `withdraw(in:coveredBy:)` can tell which notifications a
    /// read position covers.
    public var createdAt: Date
    /// Straight to Notification Center, no banner - `interruptionLevel = .passive`.
    public var isPassive: Bool
    public var playsSound: Bool
    /// Whether the notification carries a "Mark as Read" button. `false` for a
    /// conversation whose rule withholds read receipts, where
    /// `SyncEngine.submit(_:)` would refuse the mark and the button would do
    /// nothing - `CLAUDE.md`: never draw a control the seam cannot honour.
    public var offersMarkRead: Bool

    public init(
        id: String, conversationID: Conversation.ID, title: String,
        subtitle: String?, body: String, createdAt: Date,
        isPassive: Bool = false, playsSound: Bool = true, offersMarkRead: Bool = true
    ) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isPassive = isPassive
        self.playsSound = playsSound
        self.offersMarkRead = offersMarkRead
    }
}

public enum NotificationResponse: Sendable, Equatable {
    /// The notification itself was clicked: show that conversation.
    case open(Conversation.ID)
    /// Its "Mark as Read" button was pressed.
    case markRead(Conversation.ID)
}

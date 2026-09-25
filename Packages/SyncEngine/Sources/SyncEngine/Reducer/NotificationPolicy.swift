import ChatKit
import Foundation

/// Whether an arrival becomes a notification.
///
/// Pure and platform-free, and in `Reducer/` so the same import scan that
/// keeps the reducer database-free covers it: a future bridge server gating
/// push notifications runs this function, not a copy of it.
///
/// **Deliberately small.** The owner's scope for the first slice is "every
/// conversation notifies"; per-conversation mute and custom rules come later
/// and land here as more reasons. What is here are the exclusions without
/// which notifications are wrong rather than merely noisy.
///
/// How the notification looks now comes from the resolved rule the caller
/// passes in, not from a fixed shape.
public enum NotificationPolicy {
    /// How a posted notification looks - the three things macOS lets an app
    /// choose per notification (spec §1).
    public struct Presentation: Sendable, Equatable {
        /// Straight to Notification Center, no banner, no sound -
        /// `UNNotificationInterruptionLevel.passive`.
        public var isPassive: Bool
        public var playsSound: Bool
        public var showsPreview: Bool

        public init(isPassive: Bool, playsSound: Bool, showsPreview: Bool) {
            self.isPassive = isPassive
            self.playsSound = playsSound
            self.showsPreview = showsPreview
        }
    }

    public enum Decision: Sendable, Equatable {
        case post(Presentation)
        case suppress(Reason)
    }

    /// Why an arrival was not announced - carried on every suppression so a
    /// test asserts intent, and so a later "why didn't I get notified?" has
    /// an answer that is not a guess.
    public enum Reason: String, Sendable, Equatable {
        /// The local user sent it. Covers the channel echoing this client's own
        /// sends back as `messageReceived`.
        case ownMessage
        /// Nothing has said who the local user is yet, so an own message cannot
        /// be told from anyone else's. Seconds at launch; guessing wrong would
        /// notify someone of their own message.
        case identityUnknown
        /// The conversation is open in a window the user can see.
        case onScreen
        /// Already announced this session. `[Verify]` whether the real channel
        /// ever redelivers; `FixtureBackend`'s `duplicate-delivery` script does.
        case alreadyAnnounced
        /// The resolved rule says Off.
        case off
        /// Notifications are paused (spec §2.5): nothing notifies, keywords
        /// included.
        case paused
    }

    /// - Parameters:
    ///   - viewing: the conversation on screen, or `nil` when none is - no
    ///     window, a minimised one, or the app not frontmost.
    ///   - paused: whether a pause is active now - evaluated by the caller at
    ///     arrival time.
    public static func decide( // swiftlint:disable:this function_parameter_count
        _ message: Message,
        rule: ResolvedRule,
        me: Member.ID?,
        viewing: Conversation.ID?,
        alreadyAnnounced: Bool,
        paused: Bool
    ) -> Decision {
        guard let me else { return .suppress(.identityUnknown) }
        if message.sender == me {
            return .suppress(.ownMessage)
        }
        if message.conversationID == viewing {
            return .suppress(.onScreen)
        }
        if alreadyAnnounced {
            return .suppress(.alreadyAnnounced)
        }
        if paused {
            return .suppress(.paused)
        }
        switch rule.delivery {
        case .off:
            return .suppress(.off)
        case .notificationCenter:
            return .post(Presentation(isPassive: true, playsSound: false, showsPreview: rule.showsPreview))
        case .banner:
            return .post(Presentation(isPassive: false, playsSound: false, showsPreview: rule.showsPreview))
        case .bannerAndSound, .unknown:
            // Resolution never yields `.unknown`; were it ever to, the
            // built-in default is the answer rather than a guess.
            return .post(Presentation(isPassive: false, playsSound: true, showsPreview: rule.showsPreview))
        }
    }
}

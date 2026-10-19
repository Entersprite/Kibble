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
        /// The conversation is open in a window the user can see. For a reply,
        /// its thread's panel is (threads spec §4.3).
        case onScreen
        /// Already announced this session. `[Verify]` whether the real channel
        /// ever redelivers; `FixtureBackend`'s `duplicate-delivery` script does.
        case alreadyAnnounced
        /// The resolved rule says Off.
        case off
        /// Notifications are paused (spec §2.5): nothing notifies, keywords
        /// included.
        case paused
        /// The rule says mentions only, and this message does not mention you
        /// (mentions spec §3).
        case notMentioned
        /// A reply in a thread you do not follow, and it does not mention you
        /// (threads spec §4.3). Following is the stored setting, or, when
        /// nobody has said, whether you posted in the thread.
        case threadNotFollowed
    }

    /// What the policy needs about a reply's thread (threads spec §4.3).
    /// Ignored for a top-level message.
    public struct ThreadContext: Sendable, Equatable {
        /// `ThreadUnreadRule.isFollowed`: the stored setting, or whether you
        /// posted in the thread.
        public var isFollowed: Bool
        /// The thread's panel is showing, in a window the user can see: what
        /// "on screen" means for a reply.
        public var isOnScreen: Bool

        public init(isFollowed: Bool, isOnScreen: Bool) {
            self.isFollowed = isFollowed
            self.isOnScreen = isOnScreen
        }
    }

    /// Everything the policy needs to decide one arrival.
    ///
    /// Replaces what was six positional parameters behind a
    /// `function_parameter_count` disable - a context struct, as the disable
    /// it replaced said would happen.
    public struct Arrival: Sendable {
        /// The message that arrived.
        public var message: Message
        /// The rule resolved for this message's conversation.
        public var rule: ResolvedRule
        /// Who the local user is, or `nil` in the seconds at launch before
        /// anything has said so.
        public var me: Member.ID?
        /// The conversation on screen, or `nil` when none is - no window, a
        /// minimised one, or the app not frontmost.
        public var viewing: Conversation.ID?
        /// Already announced this session - `[Verify]` whether the real
        /// channel ever redelivers; `FixtureBackend`'s `duplicate-delivery`
        /// script does.
        public var alreadyAnnounced: Bool
        /// Whether a pause is active now - evaluated by the caller at arrival
        /// time.
        public var paused: Bool
        /// `Message.mentionsMe`, evaluated by the caller.
        public var mentionsMe: Bool
        /// For a reply (`message.isReply`), what is known about its thread.
        /// `nil` for a top-level message - and a reply that comes with none
        /// counts as neither followed nor on screen (`replyThread`).
        public var thread: ThreadContext?

        public init(
            message: Message,
            rule: ResolvedRule,
            me: Member.ID?,
            viewing: Conversation.ID?,
            alreadyAnnounced: Bool,
            paused: Bool,
            mentionsMe: Bool,
            thread: ThreadContext? = nil
        ) {
            self.message = message
            self.rule = rule
            self.me = me
            self.viewing = viewing
            self.alreadyAnnounced = alreadyAnnounced
            self.paused = paused
            self.mentionsMe = mentionsMe
            self.thread = thread
        }
    }

    public static func decide(_ arrival: Arrival) -> Decision {
        guard let me = arrival.me else { return .suppress(.identityUnknown) }
        if arrival.message.sender == me {
            return .suppress(.ownMessage)
        }
        if isOnScreen(arrival) {
            return .suppress(.onScreen)
        }
        if arrival.alreadyAnnounced {
            return .suppress(.alreadyAnnounced)
        }
        if arrival.paused {
            return .suppress(.paused)
        }
        if arrival.rule.delivery == .off {
            return .suppress(.off)
        }
        if let thread = arrival.replyThread, !thread.isFollowed, !arrival.mentionsMe {
            return .suppress(.threadNotFollowed)
        }
        if arrival.rule.notifyAbout == .mentions, !arrival.mentionsMe {
            return .suppress(.notMentioned)
        }
        return .post(presentation(for: arrival.rule))
    }

    /// A top-level message is on screen when its conversation is; a reply
    /// only when its thread's panel is (threads spec §4.3), because a reply is
    /// not in the transcript.
    private static func isOnScreen(_ arrival: Arrival) -> Bool {
        if let thread = arrival.replyThread {
            return thread.isOnScreen
        }
        return arrival.message.conversationID == arrival.viewing
    }

    /// The three things macOS lets an app choose per notification (spec §1),
    /// for a delivery already known not to be `.off`.
    ///
    /// Split out of `decide(_:)` to keep that function's cyclomatic
    /// complexity under the lint's limit; `.off` is unreachable here because
    /// `decide(_:)` returns before ever calling this.
    private static func presentation(for rule: ResolvedRule) -> Presentation {
        switch rule.delivery {
        case .off:
            // Unreachable: `decide(_:)` returns `.suppress(.off)` before
            // reaching this call. Kept so this switch stays exhaustive over
            // `Delivery`.
            Presentation(isPassive: true, playsSound: false, showsPreview: rule.showsPreview)
        case .notificationCenter:
            Presentation(isPassive: true, playsSound: false, showsPreview: rule.showsPreview)
        case .banner:
            Presentation(isPassive: false, playsSound: false, showsPreview: rule.showsPreview)
        case .bannerAndSound, .unknown:
            // Resolution never yields `.unknown`; were it ever to, the
            // built-in default is the answer rather than a guess.
            Presentation(isPassive: false, playsSound: true, showsPreview: rule.showsPreview)
        }
    }
}

extension NotificationPolicy.Arrival {
    /// The thread context that applies: a reply's, never a top-level
    /// message's. A reply with none is neither followed nor on screen, so only
    /// a mention gets it through (ruling 11).
    var replyThread: NotificationPolicy.ThreadContext? {
        guard message.isReply else { return nil }
        return thread ?? NotificationPolicy.ThreadContext(isFollowed: false, isOnScreen: false)
    }
}

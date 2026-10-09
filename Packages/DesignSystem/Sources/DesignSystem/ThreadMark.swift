import ChatKit
import SwiftUI

/// The mark's words (threads spec §5.1). Hand-written rather than
/// `RelativeDateTimeFormatter`, whose abbreviations move with the OS and the
/// locale (ruling 3).
enum ThreadMarkText {
    /// How long ago the last reply was, in the bands both texts use, so what
    /// is shown and what VoiceOver reads change at the same moments. A week
    /// or more is the transcript's own stamp.
    enum Age: Equatable {
        case justNow
        case minutes(Int)
        case hours(Int)
        case days(Int)
        case dated

        /// A clock that ran backwards (another device's time) is "just now".
        init(of date: Date, now: Date) {
            let seconds = max(now.timeIntervalSince(date), 0)
            switch seconds {
            case ..<60: self = .justNow
            case ..<3600: self = .minutes(Int(seconds / 60))
            case ..<86400: self = .hours(Int(seconds / 3600))
            case ..<(7 * 86400): self = .days(Int(seconds / 86400))
            default: self = .dated
            }
        }
    }

    /// `replyCount` counts the first message.
    static func count(_ thread: MessageThread) -> String {
        let replies = max(thread.replyCount - 1, 0)
        return replies == 1 ? "1 reply" : "\(replies) replies"
    }

    static func lastReply(
        at date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let ago = switch Age(of: date, now: now) {
        case .justNow: "just now"
        case let .minutes(value): "\(value)m ago"
        case let .hours(value): "\(value)h ago"
        case let .days(value): "\(value)d ago"
        case .dated: Display.timestamp(of: date, now: now, calendar: calendar, locale: locale)
        }
        return "Last reply " + ago
    }

    /// What VoiceOver reads for the whole mark: the visible words, with the
    /// units spelled out.
    static func spoken(
        _ thread: MessageThread,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var parts = [count(thread)]
        if let last = thread.lastActivity {
            parts.append("last reply " + spokenAgo(last, now: now, calendar: calendar, locale: locale))
        }
        if thread.hasUnread {
            parts.append("unread")
        }
        return parts.joined(separator: ", ")
    }

    private static func spokenAgo(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        func unit(_ value: Int, _ name: String) -> String {
            "\(value) \(name)\(value == 1 ? "" : "s") ago"
        }
        return switch Age(of: date, now: now) {
        case .justNow: "just now"
        case let .minutes(value): unit(value, "minute")
        case let .hours(value): unit(value, "hour")
        case let .days(value): unit(value, "day")
        case .dated: Display.timestamp(of: date, now: now, calendar: calendar, locale: locale)
        }
    }
}

/// The repliers' avatars, the count, the time and the unread dot, with no
/// button: the mark wraps it in one, and a Threads list row draws it as is.
///
/// The avatars only when there are some: the server's count can say replies
/// the store holds none of, and an empty stack would still take the spacing.
struct ThreadMarkLabel: View {
    let thread: MessageThread
    let directory: [Member.ID: Member]
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            if !thread.recentRepliers.isEmpty {
                HStack(spacing: -5) {
                    ForEach(Array(thread.recentRepliers.prefix(3)), id: \.self) { member in
                        Avatar(member: member, directory: directory, size: 16)
                    }
                }
            }
            Text(ThreadMarkText.count(thread))
                .font(.caption.weight(thread.hasUnread ? .semibold : .regular))
                .foregroundStyle(.tint)
            if let last = thread.lastActivity {
                Text(ThreadMarkText.lastReply(at: last, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if thread.hasUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// Under a message with replies: one button that opens its thread.
///
/// **Failable** (`CLAUDE.md`: an empty view still takes a stack's spacing): no
/// summary, no replies, a reply, or no way to open a thread means no mark, and
/// the caller writes `if let`.
struct ThreadMark: View {
    let thread: MessageThread
    let directory: [Member.ID: Member]
    /// `nil` follows the clock, redrawn every minute so "just now" moves on;
    /// a date pins it, for a test or a render.
    let now: Date?
    let open: () -> Void

    init?(
        thread: MessageThread?,
        message: Message,
        directory: [Member.ID: Member],
        now: Date? = nil,
        open: (() -> Void)?
    ) {
        guard let thread, let open, !message.isReply,
              ThreadsPresentation.hasReplies(thread) else { return nil }
        self.thread = thread
        self.directory = directory
        self.now = now
        self.open = open
    }

    var body: some View {
        if let now {
            button(now: now)
        } else {
            // `.now`, not the timeline's date, so a redraw for any other
            // reason draws now (`ConversationRow`'s rule). Never empty, so the
            // timeline costs the bubble's stack no spacing.
            TimelineView(.everyMinute) { _ in
                button(now: .now)
            }
        }
    }

    private func button(now: Date) -> some View {
        Button(action: open) {
            ThreadMarkLabel(thread: thread, directory: directory, now: now)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThreadMarkText.spoken(thread, now: now))
        .accessibilityAddTraits(.isButton)
    }
}

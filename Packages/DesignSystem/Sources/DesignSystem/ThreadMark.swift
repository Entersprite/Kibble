import ChatKit
import SwiftUI

/// The mark's words (threads spec §5.1). Hand-written rather than
/// `RelativeDateTimeFormatter`, whose abbreviations move with the OS and the
/// locale (ruling 3).
enum ThreadMarkText {
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
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "Last reply just now"
        case ..<3600: return "Last reply \(Int(seconds / 60))m ago"
        case ..<86400: return "Last reply \(Int(seconds / 3600))h ago"
        case ..<(7 * 86400): return "Last reply \(Int(seconds / 86400))d ago"
        default:
            return "Last reply " + Display.timestamp(of: date, now: now, calendar: calendar, locale: locale)
        }
    }

    /// What VoiceOver reads for the whole mark.
    static func spoken(_ thread: MessageThread, now: Date = .now) -> String {
        var parts = [count(thread)]
        if let last = thread.lastActivity {
            parts.append("last reply " + spokenAgo(max(now.timeIntervalSince(last), 0)))
        }
        if thread.hasUnread {
            parts.append("unread")
        }
        return parts.joined(separator: ", ")
    }

    private static func spokenAgo(_ seconds: TimeInterval) -> String {
        func unit(_ value: Int, _ name: String) -> String {
            "\(value) \(name)\(value == 1 ? "" : "s") ago"
        }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return unit(Int(seconds / 60), "minute")
        case ..<86400: return unit(Int(seconds / 3600), "hour")
        default: return unit(Int(seconds / 86400), "day")
        }
    }
}

/// The repliers' avatars, the count, the time and the unread dot, with no
/// button: the mark wraps it in one, and a Threads list row draws it as is.
struct ThreadMarkLabel: View {
    let thread: MessageThread
    let directory: [Member.ID: Member]
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -5) {
                ForEach(Array(thread.recentRepliers.prefix(3)), id: \.self) { member in
                    Avatar(member: member, directory: directory, size: 16)
                }
            }
            Text(ThreadMarkText.count(thread))
                .font(.caption.weight(thread.hasUnread ? .semibold : .medium))
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
    let now: Date
    let open: () -> Void

    init?(
        thread: MessageThread?,
        message: Message,
        directory: [Member.ID: Member],
        now: Date = .now,
        open: (() -> Void)?
    ) {
        guard let thread, let open, !message.isReply, thread.replyCount > 1 else { return nil }
        self.thread = thread
        self.directory = directory
        self.now = now
        self.open = open
    }

    var body: some View {
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

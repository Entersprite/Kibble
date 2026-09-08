import ChatKit
import Foundation

/// What things are called on screen.
///
/// Every function here has a fallback that is never blank. A missing name
/// renders as an empty row that looks like a rendering bug, and the one case
/// guaranteed to hit it is a Chat app: the API returns only a name and a type
/// for one, and there is no profile anywhere to look up.
public enum Display {
    /// A conversation's title, derived when the server did not send one.
    ///
    /// `nil` and `""` are different: an empty string is a title the server
    /// really sent, and deriving over it would be overriding it.
    public static func title(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?
    ) -> String {
        if let title = conversation.title {
            return title
        }
        let others = conversation.members.filter { $0 != me }
        guard !others.isEmpty else { return conversation.id.rawValue }
        return others.map { name(of: $0, in: directory) }.joined(separator: ", ")
    }

    /// A person's name, or their identifier if nobody has told us one.
    public static func name(of member: Member.ID, in directory: [Member.ID: Member]) -> String {
        resolvedName(of: member, in: directory) ?? member.rawValue
    }

    /// Whether anybody has actually told us this person's name.
    ///
    /// `name(of:in:)` cannot answer this: its fallback is the raw identifier,
    /// which is a real string and indistinguishable from a name at the call
    /// site. `Avatar` needs the difference, because Messages draws initials for
    /// someone it can name and a plain person glyph for someone it cannot -
    /// initials cut from an opaque id would be two arbitrary characters.
    public static func hasName(of member: Member.ID, in directory: [Member.ID: Member]) -> Bool {
        resolvedName(of: member, in: directory) != nil
    }

    /// The one place the "told us a name" rule lives, so `name(of:in:)` and
    /// `hasName(of:in:)` cannot answer differently.
    private static func resolvedName(
        of member: Member.ID,
        in directory: [Member.ID: Member]
    ) -> String? {
        guard let name = directory[member]?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return nil
        }
        return name
    }

    /// Who the sidebar footer says is signed in, including the moment before
    /// `me` has resolved at all.
    ///
    /// A resolved id with no directory entry yet still falls through to
    /// `name(of:in:)`'s own fallback - the raw identifier - the same partial
    /// answer `ConversationRow` and `TypingStrip` already show for anyone
    /// else not yet in the directory, so a signed-in person is not a special
    /// case. Only `me == nil` gets a different answer: there is no
    /// identifier at all to fall back to yet, and a footer visible the
    /// instant a session starts still needs to draw something during that
    /// gap. "Signed in" says a session exists without asserting an identity
    /// this client does not have - the same choice as leaving a control out
    /// entirely rather than drawing it half-empty.
    public static func signedInLabel(me: Member.ID?, directory: [Member.ID: Member]) -> String {
        guard let me else { return "Signed in" }
        return name(of: me, in: directory)
    }

    /// Up to two letters for an avatar circle.
    public static func initials(of member: Member.ID, in directory: [Member.ID: Member]) -> String {
        let resolved = name(of: member, in: directory)
        let words = resolved.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        let letters = words.prefix(2).compactMap(\.first)
        guard !letters.isEmpty else { return "?" }
        if letters.count == 1 {
            return String(resolved.prefix(2)).uppercased()
        }
        return String(letters).uppercased()
    }

    /// A message's timestamp, showing the date only once it stops being
    /// today's.
    ///
    /// | when | renders |
    /// | --- | --- |
    /// | today | `3:25 PM` |
    /// | yesterday | `Yesterday 3:25 PM` |
    /// | earlier this year | `Sep 4, 3:25 PM` |
    /// | an earlier year | `Sep 4, 2025, 3:25 PM` |
    ///
    /// ## Why `now` is a parameter
    ///
    /// `Calendar.isDateInYesterday(_:)` and
    /// `DateFormatter.doesRelativeDateFormatting` both measure against the
    /// process's real current date, which cannot be steered from a test. The
    /// branch boundaries here are midnight, a month end and a year end -
    /// exactly the places off-by-one lives - so the reference date is injected
    /// and the day arithmetic is done explicitly against it. Same reason the
    /// fixture package advances a literal `startedAt` instead of reading a
    /// clock.
    ///
    /// Comparison is on **start of day**, not elapsed hours: a message from
    /// 23:50 read at 00:10 is "Yesterday", not "20 minutes ago wearing
    /// today's label". A `date` in the future - clock skew, or a peer ahead of
    /// us - falls to the dated branches rather than being special-cased,
    /// because there is no honest short label for it.
    ///
    /// ## `[Verify]` - "Yesterday" is not localized
    ///
    /// It is the only hard-coded date word in the project, and it is hard-coded
    /// because the locale-aware options cannot take an injected reference date:
    /// `RelativeDateTimeFormatter` can, but returns a lowercase phrase whose
    /// capitalisation is not safe to fix by hand across locales. Note this is
    /// a project-wide gap rather than a local shortcut - every user-facing
    /// string in `DesignSystem` is a literal today - so this is where to start
    /// if localization arrives, not an exception to a rule that exists.
    public static func timestamp(
        of date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let base = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        let time = base.hour().minute()

        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayGap = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day

        switch dayGap {
        case 0:
            return date.formatted(time)
        case 1:
            return "Yesterday \(date.formatted(time))"
        default:
            let sameYear = calendar.component(.year, from: date)
                == calendar.component(.year, from: now)
            let dated = sameYear
                ? base.month(.abbreviated).day().hour().minute()
                : base.year().month(.abbreviated).day().hour().minute()
            return date.formatted(dated)
        }
    }
}

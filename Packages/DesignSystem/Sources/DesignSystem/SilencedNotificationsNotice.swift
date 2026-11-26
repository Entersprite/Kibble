import ChatKit
import SwiftUI

/// "Ada has notifications silenced": the line Messages draws above the field
/// while the other person in a one-to-one DM has Do not disturb on. Pure, so
/// each rule is a test; `SilencedNotificationsLine` draws it.
struct SilencedNotificationsNotice: Equatable {
    /// The other person, as the conversation's title names them.
    let name: String
    /// When their Do not disturb ends, if the backend said.
    let until: Date?

    /// The notice for `conversation`, or `nil` for none: a one-to-one DM with
    /// a person (never a group, a space or an app) whose presence is Do not
    /// disturb by `Display.presence`'s rules, connected and `me` known.
    init?(
        conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState
    ) {
        guard let partner = Display.dmPartner(of: conversation, directory: directory, me: me),
              partner.kind == .human,
              Display.presence(of: conversation, directory: directory, me: me, connection: connection)
              == .doNotDisturb
        else { return nil }
        name = Display.title(of: conversation, directory: directory, me: me)
        until = partner.doNotDisturbUntil
    }

    /// Whether the line shows at `now`: until the end passes, which can come
    /// before the next presence answer does.
    func isShown(at now: Date) -> Bool {
        until.map { now < $0 } ?? true
    }

    var text: String {
        if let until {
            "\(name) has notifications silenced until \(until.formatted(date: .omitted, time: .shortened))"
        } else {
            "\(name) has notifications silenced"
        }
    }
}

/// The notice's line: a moon and the words in the Focus color, centered, with
/// no background. It wakes itself at the end, so it leaves on time without
/// the window redrawing, and draws nothing then, taking no height in the
/// zero-spaced stack above the composer.
struct SilencedNotificationsLine: View {
    static let symbol = "moon.fill"

    let notice: SilencedNotificationsNotice
    /// The end this line has waited out. A later end, Do not disturb
    /// extended, shows the line again.
    @State private var ended: Date?

    var body: some View {
        VStack(spacing: 0) {
            if ended == nil || ended != notice.until, notice.isShown(at: .now) {
                // Messages' spacing, closer than a label's.
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol).accessibilityHidden(true)
                    Text(notice.text)
                }
                .font(.subheadline)
                .foregroundStyle(.indigo)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, TranscriptLayout.horizontalPadding)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: notice.until) {
            guard let until = notice.until else { return }
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            ended = until
        }
    }
}

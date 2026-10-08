import ChatKit
import SwiftUI

/// The window's subtitle, and the clock that redraws it on time (meeting
/// indicator spec §6.3). Moved out of `ChatWindow.swift`, which sits at
/// `file_length`; `headerClock` is not `private` for this file's sake.
extension ChatWindow {
    var subtitle: String {
        // An empty subtitle draws nothing, which is the answer when there is
        // no count worth showing.
        guard !state.showingMentions, let conversation = state.selectedConversation else { return "" }
        // A DM has no count to show, so its subtitle is the other person's
        // presence and status - `Display` decides whether there is either.
        if conversation.kind == .directMessage {
            let now = max(headerClock, .now)
            let (directory, me, connection) = (state.directory, state.me, state.connection)
            let presence = Display.presence(
                of: conversation,
                directory: directory,
                me: me,
                connection: connection
            )
            let status = Display.status(
                of: conversation, directory: directory, me: me, connection: connection, now: now
            )
            let calendar = Display.calendar(
                of: conversation, directory: directory, me: me, connection: connection, now: now
            ).flatMap { Display.calendarSummary($0, now: now) }
            return Display.headerSubtitle(presence: presence, calendar: calendar, status: status) ?? ""
        }
        return Display.memberCountLabel(of: conversation) ?? ""
    }

    /// The selected DM partner's next boundary, or `nil` for nothing to wait for.
    var nextHeaderRedraw: Date? {
        guard let conversation = state.selectedConversation else { return nil }
        let partner = Display.dmPartner(of: conversation, directory: state.directory, me: state.me)
        return Display.redrawDates(for: partner, now: .now).first
    }

    /// Sleeps to the next boundary, then moves the clock, which redraws the
    /// header and restarts this for the boundary after. A view's task, which
    /// is right here: it only redraws, and dies with the window.
    func waitForHeaderRedraw() async {
        guard let next = nextHeaderRedraw else { return }
        try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        headerClock = .now
    }
}

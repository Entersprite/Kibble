import ChatKit
import SwiftUI

/// The window's title and subtitle, the clock that redraws them on time (meeting
/// indicator spec §6.3), and the conversation column's toolbar. Moved out of
/// `ChatWindow.swift`, which sits at `file_length`; `headerClock` is not
/// `private` for this file's sake.
extension ChatWindow {
    /// Not for a one-to-one DM: its details are only the person's name and the
    /// notification settings its sidebar menu already offers.
    var showsDetailsButton: Bool {
        guard let conversation = state.selectedConversation else { return false }
        return conversation.kind != .directMessage && state.browser.page == nil &&
            state.capabilities.canReadConversationDetails && actions.browser != nil
    }

    var callConversation: Conversation.ID? {
        guard !state.showingMentions, !state.threads.showingList,
              actions.call != nil,
              let conversation = state.selectedConversation,
              conversation.kind == .directMessage,
              state.callableConversations.contains(conversation.id)
        else { return nil }
        return conversation.id
    }

    /// Where Video Call goes: beside Call, for a host whose calls carry video.
    var videoCallConversation: Conversation.ID? {
        actions.videoCall == nil ? nil : callConversation
    }

    /// The conversation column's toolbar.
    ///
    /// The flexible spacer draws nothing and is always there: it keeps the
    /// toolbar, so its band is 52 pt and two rows, and the thread's titlebar
    /// section (session 65, `ThreadColumnBridge`). Details and the calls never
    /// share the band, since Details leaves out a DM and only a DM has calls.
    /// Call and Video Call are neighbors with no spacer between them, so they
    /// share one glass capsule, as a pair of related actions does.
    @ToolbarContentBuilder var conversationToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        if showsDetailsButton, let conversation = state.selectedConversation, let browser = actions.browser {
            ToolbarItem(placement: .primaryAction) {
                let meeting = state.meetingSeries != nil
                let title = meeting ? "Latest Meeting Details" : "Conversation Details"
                Button(title, systemImage: "info.circle") { browser.details(conversation.id, false) }
                    .help(meeting ? "Show the latest meeting’s details" : "Show conversation details")
            }
        }
        if let callConversation, let call = actions.call {
            Self.favored(ToolbarItem(placement: .primaryAction) {
                Button("Call", systemImage: "phone") { call(callConversation) }
                    .help("Start audio call")
            })
        }
        if let videoCallConversation, let videoCall = actions.videoCall {
            Self.favored(ToolbarItem(placement: .primaryAction) {
                Button("Video Call", systemImage: "video") { videoCall(videoCallConversation) }
                    .help("Start video call")
            })
        }
    }

    /// The calls stay in the toolbar longest when the window is too narrow for
    /// every item. The priority arrived in macOS 26.1; on 26.0 the item keeps
    /// the automatic order.
    @ToolbarContentBuilder private static func favored(_ item: some ToolbarContent) -> some ToolbarContent {
        if #available(macOS 26.1, iOS 27, *) {
            item.visibilityPriority(.high)
        } else {
            item
        }
    }

    var title: String {
        if state.browser.page == "spaceSpam" {
            return "Spam Invitations"
        }
        if state.browser.page == "space" {
            return "Browse Spaces"
        }
        if let page = state.browser.page {
            return page == "people" || page == "directMessage" ? "People" : SidebarSectionPreference(id: page)
                .title
        }
        if state.showingMentions {
            return "Mentions"
        }
        if state.threads.showingList {
            return ThreadsPresentation.title
        }
        guard let conversation = state.selectedConversation else { return "Kibble" }
        if let series = state.meetingSeries {
            return series.title
        }
        return Display.title(of: conversation, directory: state.directory, me: state.me)
    }

    var subtitle: String {
        // An empty subtitle draws nothing, which is the answer when there is
        // no count worth showing.
        guard state.browser.page == nil, !state.showingMentions, !state.threads.showingList,
              let conversation = state.selectedConversation else { return "" }
        // The saved copy is on screen and its newest page is on the way.
        if state.isLoadingMessages, !state.unconfirmedMessages.isEmpty {
            return "Updating…"
        }
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

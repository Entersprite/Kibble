import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The menu bar's Conversation menu: what it draws for the host's actions,
/// what it enables for the window's state, the sidebar order its stepping
/// and Command-digits follow, and where each command goes.
@MainActor
struct ConversationMenuBarTests {
    private let me = Member.ID("me")
    private let ann = Member(id: Member.ID("ann"), kind: .human, displayName: "Ann")
    private let bo = Member(id: Member.ID("bo"), kind: .human, displayName: "Bo")

    private var annDM: Conversation {
        Conversation(
            id: .init("dm-ann"), kind: .directMessage, lastActivity: Date(timeIntervalSince1970: 30),
            hasUnread: true, members: [me, ann.id]
        )
    }

    private var boDM: Conversation {
        Conversation(
            id: .init("dm-bo"), kind: .directMessage, lastActivity: Date(timeIntervalSince1970: 20),
            members: [me, bo.id]
        )
    }

    private var deploys: Conversation {
        Conversation(id: .init("deploys"), kind: .space, title: "Deploys", repliesEnabled: true)
    }

    private var alpha: Conversation {
        Conversation(id: .init("alpha"), kind: .space, title: "Alpha")
    }

    private func state(
        selected: Conversation.ID? = nil, configure: (inout ChatSceneState) -> Void = { _ in }
    ) -> ChatSceneState {
        var state = ChatSceneState(
            conversations: [deploys, annDM, alpha, boDM],
            directory: [ann.id: ann, bo.id: bo],
            me: me,
            selected: selected,
            capabilities: Capabilities(canReadConversationDetails: true)
        )
        configure(&state)
        return state
    }

    private func entry(_ id: String, in menu: ConversationMenuBar) -> ConversationMenuBar.Entry? {
        menu.sections.joined().first { $0.id == id }
    }

    private func ids(_ menu: ConversationMenuBar) -> [String] {
        menu.sections.joined().map(\.id)
    }

    // MARK: Drawn only where the host offers it

    @Test func withNoActionsOfferedOnlyStepsAndTheListedRowsAreDrawn() {
        let menu = ConversationMenuBar(state: state(), actions: ChatSceneActions())
        #expect(ids(menu) == ["next", "previous", "listed.0", "listed.1", "listed.2", "listed.3"])
    }

    @Test func everyOfferedItemIsDrawnInOrder() {
        let recorder = MenuActionRecorder()
        let menu = ConversationMenuBar(state: state(), actions: recorder.actions)
        #expect(menu.sections.map { $0.map(\.id) } == [
            ["details", "call", "videoCall"],
            ["markAsRead", "mute", "notificationSettings"],
            ["follow", "closeThread"],
            ["mentions", "threads"],
            ["next", "previous"],
            ["listed.0", "listed.1", "listed.2", "listed.3"]
        ])
        // A backend that cannot read details gets no Show Details.
        let noDetails = state { $0.capabilities = Capabilities() }
        #expect(!ids(ConversationMenuBar(state: noDetails, actions: recorder.actions)).contains("details"))
    }

    @Test func withoutTheWindowEveryDrawnItemIsDisabledAndNoRowIsListed() {
        let recorder = MenuActionRecorder()
        let menu = ConversationMenuBar(state: nil, actions: recorder.actions)
        #expect(ids(menu) == [
            "details", "call", "videoCall", "markAsRead", "mute", "notificationSettings", "follow",
            "closeThread", "mentions", "threads", "next", "previous"
        ])
        #expect(menu.sections.joined().allSatisfy { !$0.isEnabled })
        #expect(menu.account == nil)
    }

    // MARK: Enabled as the window offers it

    /// The toolbar's own gates, read off `ChatWindow` for the same state.
    @Test func detailsAndCallsAreEnabledExactlyWhereTheToolbarDrawsThem() {
        let recorder = MenuActionRecorder()
        let states = [
            state(),
            state(selected: deploys.id),
            state(selected: deploys.id) { $0.browser.page = "space" },
            state(selected: deploys.id) { $0.capabilities = Capabilities() },
            state(selected: annDM.id),
            state(selected: annDM.id) { $0.callableConversations = [annDM.id] },
            state(selected: annDM.id) { $0.callableConversations = [annDM.id]; $0.showingMentions = true },
            state(selected: boDM.id) { $0.callableConversations = [annDM.id] }
        ]
        for state in states {
            let menu = ConversationMenuBar(state: state, actions: recorder.actions)
            let window = ChatWindow(state: state, actions: recorder.actions)
            let details = entry("details", in: menu)?.command
            #expect(details == (window.showsDetailsButton ? state.selected.map { .details($0) } : nil))
            let video = window.videoCallConversation.map { ConversationMenuBar.Command.videoCall($0) }
            #expect(entry("call", in: menu)?.command == window.callConversation.map { .call($0) })
            #expect(entry("videoCall", in: menu)?.command == video)
        }
    }

    @Test func markAsReadMuteAndNotificationsFollowTheRowMenu() {
        let recorder = MenuActionRecorder()
        let unread = ConversationMenuBar(state: state(selected: annDM.id), actions: recorder.actions)
        #expect(entry("markAsRead", in: unread)?.command == .markAsRead([annDM.id]))
        #expect(entry("markAsRead", in: unread)?.shortcut == MenuBarShortcuts.markAsRead)
        #expect(entry("mute", in: unread)?.title == "Mute")
        #expect(entry("mute", in: unread)?.command == .mute([annDM.id]))
        #expect(entry("notificationSettings", in: unread)?.command == .notificationSettings(annDM.id))

        let read = ConversationMenuBar(
            state: state(selected: boDM.id) { $0.muted = [boDM.id] },
            actions: recorder.actions
        )
        #expect(entry("markAsRead", in: read)?.isEnabled == false)
        #expect(entry("mute", in: read)?.title == "Unmute")
        #expect(entry("mute", in: read)?.command == .unmute([boDM.id]))

        let withheld = state(selected: annDM.id) { $0.receiptsWithheld = [annDM.id] }
        #expect(entry("markAsRead", in: ConversationMenuBar(state: withheld, actions: recorder.actions))?
            .isEnabled == false)
        let mentions = state(selected: nil) { $0.showingMentions = true }
        let pane = ConversationMenuBar(state: mentions, actions: recorder.actions)
        #expect(["markAsRead", "mute", "notificationSettings"]
            .allSatisfy { entry($0, in: pane)?.isEnabled == false })
    }

    @Test func aMeetingSeriesActsOnItsChatsAsItsRowMenuDoes() {
        let recorder = MenuActionRecorder()
        func occurrence(_ id: String, start: Double) -> Conversation {
            Conversation(
                id: .init(id), kind: .meetChat, title: "Planning - occurrence",
                lastActivity: Date(timeIntervalSince1970: start), hasUnread: true,
                meeting: MeetingOccurrence(
                    seriesID: .init("planning"), occurrenceID: id, seriesTitle: "Planning",
                    scheduledStart: Date(timeIntervalSince1970: start)
                )
            )
        }
        let chats = [occurrence("one", start: 100), occurrence("two", start: 200)]
        var series = ChatSceneState(conversations: chats)
        series.selectedMeetingSeries = MeetingSeries.build(chats).first?.id
        let menu = ConversationMenuBar(state: series, actions: recorder.actions)
        guard case let .markAsRead(targets)? = entry("markAsRead", in: menu)?.command else {
            Issue.record("Mark as Read is not enabled for an unread series")
            return
        }
        #expect(Set(targets) == [.init("one"), .init("two")])
        #expect(entry("notificationSettings", in: menu)?.isEnabled == false)
        #expect(ids(menu).contains("listed.0"))

        var noSeries = recorder.actions
        noSeries.selectMeetingSeries = nil
        #expect(!ids(ConversationMenuBar(state: series, actions: noSeries)).contains("listed.0"))
    }

    @Test func theThreadItemsFollowTheOpenThreadColumn() {
        let recorder = MenuActionRecorder()
        let thread = MessageThread(id: .init("t-1"), conversationID: deploys.id, isFollowed: true)
        func menu(_ configure: (inout ChatSceneState) -> Void) -> ConversationMenuBar {
            ConversationMenuBar(
                state: state(selected: deploys.id, configure: configure),
                actions: recorder.actions
            )
        }
        let open = menu { $0.threads.panel = ThreadPanelState(thread: thread, conversationTitle: "Deploys") }
        #expect(entry("follow", in: open)?.style == .checkmark(isOn: true))
        #expect(entry("follow", in: open)?.command == .setFollowed(false))
        #expect(entry("closeThread", in: open)?.command == .closeThread)

        let pending = menu {
            $0.threads.panel = ThreadPanelState(
                thread: thread,
                conversationTitle: "Deploys",
                followPending: true
            )
        }
        #expect(entry("follow", in: pending)?.isEnabled == false)
        #expect(entry("closeThread", in: pending)?.isEnabled == true)

        let closed = menu { _ in }
        #expect(entry("follow", in: closed)?.style == .checkmark(isOn: false))
        #expect(entry("follow", in: closed)?.isEnabled == false)
        #expect(entry("closeThread", in: closed)?.isEnabled == false)

        // A conversation without replies draws no thread column, so none acts.
        let noReplies = ConversationMenuBar(state: state(selected: alpha.id) {
            $0.threads.panel = ThreadPanelState(thread: thread, conversationTitle: "Alpha")
        }, actions: recorder.actions)
        #expect(entry("closeThread", in: noReplies)?.isEnabled == false)
    }

    /// Close Thread works exactly while the window draws the thread column.
    @Test func closeThreadIsEnabledExactlyWhereTheThreadColumnIsShown() {
        let recorder = MenuActionRecorder()
        let thread = MessageThread(id: .init("t-1"), conversationID: deploys.id)
        let panel = ThreadPanelState(thread: thread, conversationTitle: "Deploys")
        let states = [
            state(selected: deploys.id),
            state(selected: deploys.id) { $0.threads.panel = panel },
            state(selected: deploys.id) { $0.threads.panel = panel; $0.threads.showingList = true },
            state(selected: deploys.id) { $0.threads.panel = panel; $0.showingMentions = true },
            state(selected: alpha.id) { $0.threads.panel = panel },
            state(selected: nil) { $0.threads.panel = panel }
        ]
        for state in states {
            let menu = ConversationMenuBar(state: state, actions: recorder.actions)
            let window = ChatWindow(state: state, actions: recorder.actions)
            #expect(entry("closeThread", in: menu)?.isEnabled == window.threadColumnShown)
        }
    }

    // MARK: The sidebar's order

    @Test func theOrderIsTheSidebarsRowsWithCollapsedSectionsLeftOut() {
        let recorder = MenuActionRecorder()
        let order = { (state: ChatSceneState, actions: ChatSceneActions) in
            ConversationMenuBar.visibleOrder(state, actions: actions).map(\.id)
        }
        let all: [SidebarSelection] = [
            .conversation(annDM.id), .conversation(boDM.id), .conversation(alpha.id),
            .conversation(deploys.id)
        ]
        #expect(order(state(), recorder.actions) == all)
        let collapsed = state { $0.collapsedSections = ["space"] }
        #expect(order(collapsed, recorder.actions) == Array(all.prefix(2)))
        // A host that does not keep collapse cannot say what is collapsed.
        var forgetful = recorder.actions
        forgetful.setSectionCollapsed = nil
        #expect(order(collapsed, forgetful) == all)
        // A favorite is listed once, where Favorites puts it first.
        let favorite = state { $0.sidebarPreferences.favoriteConversations = [deploys.id] }
        #expect(order(favorite, recorder.actions) == [all[3]] + all.prefix(3))
    }

    @Test func stepsGoDownAndUpTheSidebarWithoutWrapping() {
        let recorder = MenuActionRecorder()
        func steps(_ state: ChatSceneState) -> (ConversationMenuBar.Command?, ConversationMenuBar.Command?) {
            let menu = ConversationMenuBar(state: state, actions: recorder.actions)
            return (entry("next", in: menu)?.command, entry("previous", in: menu)?.command)
        }
        #expect(steps(state(selected: boDM.id)) == (
            .select(.conversation(alpha.id)),
            .select(.conversation(annDM.id))
        ))
        #expect(steps(state(selected: annDM.id)) == (.select(.conversation(boDM.id)), nil))
        #expect(steps(state(selected: deploys.id)) == (nil, .select(.conversation(alpha.id))))
        // From Mentions, or nothing selected, Next starts at the top and
        // Previous at the bottom.
        let mentions = state { $0.showingMentions = true }
        #expect(steps(mentions) == (.select(.conversation(annDM.id)), .select(.conversation(deploys.id))))
        #expect(steps(state(selected: nil)) == (
            .select(.conversation(annDM.id)),
            .select(.conversation(deploys.id))
        ))
        let menu = ConversationMenuBar(state: state(), actions: recorder.actions)
        #expect(entry("next", in: menu)?.shortcut == MenuBarShortcuts.nextConversation)
        #expect(entry("previous", in: menu)?.shortcut == MenuBarShortcuts.previousConversation)
    }

    @Test func theFirstNineRowsAreListedOnCommandDigitsWithTheSelectionChecked() throws {
        let recorder = MenuActionRecorder()
        let many = (0 ..< 12).map { number in
            Conversation(
                id: .init("dm-\(number)"), kind: .directMessage, title: "Person \(number)",
                lastActivity: Date(timeIntervalSince1970: Double(100 - number))
            )
        }
        var preferences = SidebarPreferences()
        preferences.update(.init(id: "directMessage", maximumItems: 20))
        var state = ChatSceneState(conversations: many, selected: many[2].id)
        state.sidebarPreferences = preferences
        let menu = ConversationMenuBar(state: state, actions: recorder.actions)
        let listed = try #require(menu.sections.last)
        #expect(listed.count == 9)
        #expect(listed.map(\.shortcut) == (0 ..< 9).map { MenuBarShortcuts.conversation($0) })
        #expect(listed.map(\.command) == many.prefix(9).map { .select(.conversation($0.id)) })
        #expect(listed.map(\.style) == (0 ..< 9).map { .checkmark(isOn: $0 == 2) })
    }

    // MARK: Where each command goes

    @Test func eachCommandGoesToTheWindowsOwnAction() {
        let recorder = MenuActionRecorder()
        let commands: [ConversationMenuBar.Command] = [
            .details(deploys.id), .call(annDM.id), .videoCall(annDM.id), .markAsRead([annDM.id, boDM.id]),
            .mute([annDM.id]), .unmute([boDM.id]), .notificationSettings(annDM.id), .setFollowed(true),
            .closeThread, .mentions, .threads, .select(.conversation(boDM.id)),
            .select(.meetingSeries(.init("p")))
        ]
        for command in commands {
            ConversationMenuBar.perform(command, actions: recorder.actions)
        }
        #expect(recorder.log == [
            "details deploys", "call dm-ann", "video dm-ann", "read dm-ann", "read dm-bo", "mute dm-ann",
            "unmute dm-bo", "notifications dm-ann", "follow true", "close thread", "mentions", "threads",
            "select dm-bo", "series p"
        ])
    }
}

/// Every action the Conversation menu can reach, each writing what it was
/// asked into one log.
@MainActor
final class MenuActionRecorder {
    var log: [String] = []

    var actions: ChatSceneActions {
        var actions = ChatSceneActions(
            select: { [unowned self] in log.append("select \($0.rawValue)") },
            mute: { [unowned self] in log.append("mute \($0.rawValue)") },
            unmute: { [unowned self] in log.append("unmute \($0.rawValue)") },
            markRead: { [unowned self] in log.append("read \($0.rawValue)") },
            showNotificationSettings: { [unowned self] in log.append("notifications \($0.rawValue)") },
            showMentions: { [unowned self] in log.append("mentions") },
            threads: ThreadActions(
                open: { _ in }, close: { [unowned self] in log.append("close thread") }, sendReply: { _ in },
                setFollowed: { [unowned self] in log.append("follow \($0)") }, markUnread: { _ in },
                showList: { [unowned self] in log.append("threads") }, openItem: { _, _ in }
            ),
            setSectionCollapsed: { _, _ in },
            call: { [unowned self] in log.append("call \($0.rawValue)") }
        )
        actions.videoCall = { [unowned self] in log.append("video \($0.rawValue)") }
        actions.selectMeetingSeries = { [unowned self] in log.append("series \($0.rawValue)") }
        actions.browser = ConversationBrowserActions(
            show: { _ in }, back: {}, search: { _, _, _ in }, reviewCreation: {}, searchPeople: { _ in },
            beginCreation: { _ in }, create: { _ in }, closePanel: {},
            details: { [unowned self] id, _ in log.append("details \(id.rawValue)") }, preview: { _ in },
            mutate: { _ in }
        )
        actions.search = SearchActions(
            show: {}, hide: {}, textChanged: { _ in }, setQuery: { _ in }, submit: {}, loadMore: {},
            openConversation: { _ in }, openPerson: { _ in }, openMessage: { _ in },
            step: { [unowned self] in log.append("step \($0)") }, end: {}
        )
        return actions
    }
}

import ChatKit
import SwiftUI

/// Back and Forward (`NavigationHistory`): what the window records, and how
/// it returns to a recorded place through the same actions a click uses.
/// Out of `ChatWindow.swift`, which sits near `file_length`.
extension ChatWindow {
    /// Where the window is now, or `nil` while nothing is chosen.
    var navigationPlace: NavigationPlace? {
        if let page = state.browser.page {
            return .page(page)
        }
        return state.sidebarSelection.map { .sidebar($0, thread: state.threads.panel?.thread.id) }
    }

    var navigationHistory: NavigationHistory {
        navigationHistories[state.accountID ?? ""] ?? NavigationHistory()
    }

    /// Hands this render's `step` to the menu bar's commands as it draws.
    var navigationRecording: NavigationRecording {
        navigationStepper.step = step
        return NavigationRecording(
            account: state.accountID,
            place: navigationPlace,
            history: navigationHistory,
            histories: $navigationHistories,
            stepper: navigationStepper
        )
    }

    /// Steps the selected account's history and goes where it lands.
    func step(_ step: NavigationStep) {
        let key = state.accountID ?? ""
        var history = navigationHistories[key] ?? NavigationHistory()
        let place = switch step {
        case .back: history.back(where: canShow)
        case .forward: history.forward(where: canShow)
        }
        navigationHistories[key] = history
        if let place {
            go(to: place)
        }
    }

    /// Whether a recorded place still exists and this session can show it.
    private func canShow(_ place: NavigationPlace) -> Bool {
        switch place {
        case .page:
            actions.browser != nil
        case let .sidebar(selection, thread):
            switch selection {
            case let .conversation(id):
                state.conversations.contains { $0.id == id }
                    && (thread == nil || actions.threads != nil)
            case let .meetingSeries(id):
                actions.selectMeetingSeries != nil
                    && MeetingSeries.build(state.conversations).contains { $0.id == id }
            case .mentions:
                actions.showMentions != nil
            case .threads:
                actions.threads != nil
            case .calls:
                actions.callHistory != nil
            }
        }
    }

    /// Opens a place as the sidebar, a directory link or a thread mark would.
    /// The visit this causes is the history's current place, so it records
    /// nothing (`NavigationHistory.visit`).
    private func go(to place: NavigationPlace) {
        switch place {
        case let .page(page):
            actions.browser?.show(page)
        case let .sidebar(.conversation(id), thread?):
            // As a Threads list item opens: the transcript scrolls to the
            // thread's first message.
            actions.threads?.openItem(id, thread)
        case let .sidebar(selection, thread):
            switch selection {
            case let .conversation(id): actions.select(id)
            case let .meetingSeries(id): actions.selectMeetingSeries?(id)
            case .mentions: actions.showMentions?()
            case .threads: actions.threads?.showList()
            case .calls: actions.callHistory?.show()
            }
            if let thread {
                actions.threads?.open(thread)
            } else if state.threads.panel != nil {
                actions.threads?.close()
            }
        }
    }
}

/// Records each place the window shows in its account's history, and offers
/// Back and Forward to the menu bar.
struct NavigationRecording: ViewModifier {
    let account: String?
    let place: NavigationPlace?
    let history: NavigationHistory
    @Binding var histories: [String: NavigationHistory]
    let stepper: NavigationStepper

    func body(content: Content) -> some View {
        content
            .onChange(of: AccountScoped(account: account, value: place), initial: true) { _, scoped in
                guard let place = scoped.value else { return }
                histories[scoped.account ?? "", default: NavigationHistory()].visit(place)
            }
            .focusedSceneValue(
                \.navigationHistory,
                NavigationHistoryCommands(
                    scope: account,
                    canGoBack: history.canGoBack,
                    canGoForward: history.canGoForward
                ) { [stepper] in stepper.step($0) }
            )
    }
}

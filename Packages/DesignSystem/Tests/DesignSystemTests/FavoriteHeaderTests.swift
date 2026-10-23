import ChatKit
import Testing
@testable import DesignSystem

/// The header's star adds the open conversation or meeting to Favorites and
/// shows, filled, that it is one.
@MainActor
struct FavoriteHeaderTests {
    private let id = Conversation.ID("space/1")

    private func header(
        selected: Bool = true,
        mentions: Bool = false,
        threads: Bool = false,
        page: String? = nil
    ) -> ChatWindow {
        var actions = ChatSceneActions()
        actions.updateSidebar = { _ in }
        var state = ChatSceneState(
            conversations: [Conversation(id: id, kind: .space)],
            selected: selected ? id : nil,
            showingMentions: mentions,
            threads: ThreadSceneState(showingList: threads)
        )
        state.browser.page = page
        return ChatWindow(state: state, actions: actions)
    }

    @Test func theStarTargetsTheOpenConversation() {
        #expect(header().favoriteTarget == .conversation(id))
    }

    @Test func listsPagesAndNothingSelectedHaveNoStar() {
        #expect(header(selected: false).favoriteTarget == nil)
        #expect(header(selected: false, mentions: true).favoriteTarget == nil)
        #expect(header(selected: false, threads: true).favoriteTarget == nil)
        #expect(header(page: "people").favoriteTarget == nil)
    }

    @Test func aMeetingIsStarredByItsSeries() {
        let series = MeetingSeries.ID("series")
        var state = header().state
        state.selectedMeetingSeries = series
        let window = ChatWindow(state: state, actions: ChatSceneActions())
        #expect(window.favoriteTarget == .meetingSeries(series))
    }

    @Test func theStarIsFilledWhileItIsAFavorite() {
        let target = SidebarSelection.conversation(id)
        let empty = SidebarPreferences()
        let added = FavoriteMenu.toggling(target, in: empty)
        #expect(FavoriteMenu.headerItem(for: target, in: empty) == ("Add to Favorites", "star"))
        #expect(FavoriteMenu.headerItem(for: target, in: added) == ("Remove from Favorites", "star.fill"))
    }
}

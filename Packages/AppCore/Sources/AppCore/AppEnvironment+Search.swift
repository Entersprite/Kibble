import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// Search, as the window sees it (search spec §1): the model's
/// `SearchSessionState` mapped into `SearchSceneState`, its methods as
/// `SearchActions`, and the menu's entry points.
public extension AppEnvironment {
    internal static func searchScene(_ search: SearchSessionState) -> SearchSceneState {
        SearchSceneState(
            isShown: search.isShown, query: search.query, conversations: search.conversations,
            people: search.people, hits: search.hits, isSearching: search.isSearching,
            isLoadingMore: search.isLoadingMore, loadMoreFailed: search.loadMoreFailed,
            hasMore: search.next != nil, failed: search.failed, recents: search.recents, focus: search.focus,
            focusGeneration: search.focusGeneration,
            bar: search.bar.map { bar in
                SearchBarScene(
                    query: bar.query, index: bar.index, count: bar.hits.count, hasMore: bar.next != nil,
                    isOpening: bar.isOpening, unreachable: bar.unreachable.map(unreachable),
                    pageFailed: bar.pageFailed
                )
            }
        )
    }

    private static func unreachable(_ reason: SearchBarState.Unreachable) -> SearchBarScene.Unreachable {
        switch reason {
        case .tooFarBack: .tooFarBack
        case .notInSidebar: .notInSidebar
        }
    }

    /// Offered only while a session runs on a backend that can search.
    internal var searchActions: SearchActions? {
        guard runningModel?.capabilities.canSearchMessages == true else { return nil }
        return SearchActions(
            show: { [weak self] in self?.runningModel?.showSearch() },
            hide: { [weak self] in self?.runningModel?.hideSearch() },
            textChanged: { [weak self] in self?.runningModel?.searchTextChanged($0) },
            setQuery: { [weak self] in self?.runningModel?.setSearchQuery($0) },
            submit: { [weak self] in self?.runningModel?.submitSearch() },
            loadMore: { [weak self] in self?.runningModel?.loadMoreSearchResults() },
            openConversation: { [weak self] in self?.runningModel?.openSearchConversation($0) },
            openPerson: { [weak self] in self?.runningModel?.openSearchPerson($0) },
            openMessage: { [weak self] in self?.runningModel?.openSearchResult($0) },
            step: { [weak self] in self?.runningModel?.stepSearchResult(by: $0) },
            end: { [weak self] in self?.runningModel?.endSearch() }
        )
    }

    /// Edit › Search… (⌘F).
    var canSearch: Bool {
        runningModel?.capabilities.canSearchMessages == true
    }

    func showSearch() {
        runningModel?.showSearch()
    }

    /// Edit › Next Result and Previous Result (⌘G, ⇧⌘G): the model's rule,
    /// which refuses while the overlay is shown.
    var canStepSearch: Bool {
        runningModel?.canStepSearch == true
    }

    func stepSearch(_ step: Int) {
        runningModel?.stepSearchResult(by: step)
    }
}

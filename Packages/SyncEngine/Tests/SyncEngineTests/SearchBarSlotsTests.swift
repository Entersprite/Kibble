import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The search's bar beside its list (search fix wave): their pages apart, ⌘G
/// only without the overlay, the same hit opened again, and the list's "more"
/// page after a failure.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SearchBarSlotsTests {
    static func hit(_ index: Int) -> Message {
        SearchOpenTests.hit(index)
    }

    /// Finding 2: a step of the bar cancels the bar's page only, so a list
    /// page out lands and clears `isLoadingMore`.
    @Test func aHeldListPageSurvivesABarStep() async throws {
        let (model, backend) = try await SearchOpenTests.searched([
            MessageSearchPage(hits: [Self.hit(11), Self.hit(10)], next: MessageSearchCursor("1")),
            MessageSearchPage(hits: [Self.hit(9)])
        ])
        model.openSearchResult(Self.hit(11).id)
        await settleAutoMarkRead(until: "hit 11 opens") { model.scrollTarget == Self.hit(11).id }
        model.showSearch()
        await backend.holdMessageSearches(true)
        model.loadMoreSearchResults()
        await settleAutoMarkRead(until: "the list's page is held") {
            await backend.abortableMessageSearches.count == 1
        }
        #expect(model.search.isLoadingMore)
        model.hideSearch()
        model.stepSearchResult(by: 1)
        #expect(model.search.bar?.index == 1)
        await backend.holdMessageSearches(false)
        await backend.abortableMessageSearches.release()
        await settleAutoMarkRead(until: "the list's page lands") { !model.search.isLoadingMore }
        let aborted = await backend.abortableMessageSearches.aborted
        #expect(aborted == 0)
        #expect(model.search.hits.map(\.id) == [Self.hit(11).id, Self.hit(10).id, Self.hit(9).id])
        await model.stop()
    }

    /// Finding 2: ⌘G steps the bar only while the overlay is not over it.
    @Test func stepsAreOfferedOnlyWithoutTheOverlay() async throws {
        let (model, _) = try await SearchOpenTests.searched([MessageSearchPage(hits: [Self.hit(11)])])
        #expect(!model.canStepSearch)
        model.openSearchResult(Self.hit(11).id)
        #expect(model.canStepSearch)
        model.showSearch()
        #expect(!model.canStepSearch)
        model.hideSearch()
        #expect(model.canStepSearch)
        await model.stop()
    }

    /// Finding 3: opening the hit already open is a new open, so the window
    /// scrolls to it and marks it again.
    @Test func theSameHitOpenedAgainIsANewOpen() async throws {
        let (model, _) = try await SearchOpenTests.searched([MessageSearchPage(hits: [Self.hit(11)])])
        model.openSearchResult(Self.hit(11).id)
        await settleAutoMarkRead(until: "it opens") { model.search.openGeneration == 1 }
        model.showSearch()
        model.openSearchResult(Self.hit(11).id)
        await settleAutoMarkRead(until: "it opens again") { model.search.openGeneration == 2 }
        #expect(model.search.highlight == Self.hit(11).id)
        #expect(model.scrollTarget == Self.hit(11).id)
        await model.stop()
    }

    /// Finding 4: the recent's save is tracked, so `stop()` cancels it.
    @Test func stopCancelsTheRecentsSave() async throws {
        let (model, _) = try await SearchOpenTests.searched([MessageSearchPage(hits: [Self.hit(11)])])
        model.openSearchResult(Self.hit(11).id)
        let save = try #require(model.searchWork.recordTask)
        await model.stop()
        #expect(model.searchWork.recordTask == nil)
        #expect(save.isCancelled)
    }

    /// Finding 6: a failed "more" page is said, and a retry asks again.
    @Test func aFailedPageOffersARetry() async throws {
        let (model, backend) = try await SearchOpenTests.searched([
            MessageSearchPage(hits: [Self.hit(11)], next: MessageSearchCursor("1")),
            MessageSearchPage(hits: [Self.hit(10)])
        ])
        await backend.failMessageSearches(true)
        model.loadMoreSearchResults()
        await settleAutoMarkRead(until: "the page fails") { model.search.loadMoreFailed }
        #expect(!model.search.isLoadingMore)
        await backend.failMessageSearches(false)
        model.loadMoreSearchResults()
        #expect(!model.search.loadMoreFailed)
        await settleAutoMarkRead(until: "the retry lands") { model.search.hits.count == 2 }
        #expect(!model.search.loadMoreFailed)
        await model.stop()
    }

    /// A page the bar steps past the loaded end to reach can fail the same
    /// way the list's "more" page can: said beside the position, the index
    /// and the loaded hits untouched, and the next step past the end (⌘G or
    /// ›) retries, clearing the message as soon as it asks again.
    @Test func aFailedBarPageSaysSoAndTheNextStepRetries() async throws {
        let (model, backend) = try await SearchOpenTests.searched([
            MessageSearchPage(hits: [Self.hit(11)], next: MessageSearchCursor("1")),
            MessageSearchPage(hits: [Self.hit(10)])
        ])
        model.openSearchResult(Self.hit(11).id)
        await settleAutoMarkRead(until: "hit 11 opens") { model.scrollTarget == Self.hit(11).id }
        await backend.failMessageSearches(true)
        model.stepSearchResult(by: 1)
        await settleAutoMarkRead(until: "the page fails") { model.search.bar?.pageFailed == true }
        #expect(model.search.bar?.index == 0)
        #expect(model.search.bar?.hits.count == 1)
        #expect(model.search.bar?.isOpening == false)
        #expect(model.scrollTarget == Self.hit(11).id)
        await backend.failMessageSearches(false)
        model.stepSearchResult(by: 1)
        // Cleared the moment the retry asks, not when it lands.
        #expect(model.search.bar?.pageFailed == false)
        await settleAutoMarkRead(until: "the retry lands") { model.search.bar?.index == 1 }
        #expect(model.search.bar?.pageFailed == false)
        #expect(model.search.bar?.hits.count == 2)
        await model.stop()
    }

    /// ⌘F back to the bar at the same position restamps the same focus
    /// value, so the overlay cannot tell it apart from one that never
    /// changed. `focusGeneration` is the signal it watches instead, bumped
    /// here regardless of whether the restamped value differs.
    @Test func reshowingAtTheSamePositionStillBumpsTheFocusGeneration() async throws {
        let (model, _) = try await SearchOpenTests.searched([MessageSearchPage(hits: [Self.hit(11)])])
        model.openSearchResult(Self.hit(11).id)
        await settleAutoMarkRead(until: "it opens") { model.scrollTarget == Self.hit(11).id }
        model.showSearch()
        #expect(model.search.focus == Self.hit(11).id)
        let first = model.search.focusGeneration
        model.hideSearch()
        model.showSearch()
        #expect(model.search.focus == Self.hit(11).id)
        #expect(model.search.focusGeneration == first + 1)
        await model.stop()
    }
}

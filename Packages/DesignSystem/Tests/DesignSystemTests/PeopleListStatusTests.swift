import ChatKit
import Testing
@testable import DesignSystem

/// The People tab never stands empty under its member count: it says the
/// list is loading, or why it could not load, with a way to ask again.
struct PeopleListStatusTests {
    @Test func aPageOnItsWayIsLoading() {
        var browser = ConversationBrowserScene()
        browser.isLoadingParticipants = true
        #expect(PeopleListStatus.of(browser) == .loading)
    }

    @Test func aFailedLoadWithNobodyShownSaysWhy() {
        var browser = ConversationBrowserScene()
        browser.panelError = "The account operation could not be completed."
        #expect(PeopleListStatus.of(browser) == .failed("The account operation could not be completed."))
    }

    @Test func peopleShownStayShownWhateverElseHappens() {
        var browser = ConversationBrowserScene()
        browser.participants = [ConversationParticipant(
            member: Member(id: .init("u-1"), kind: .human, displayName: "Ada"),
            role: .member, state: .joined
        )]
        browser.panelError = "A later page failed."
        #expect(PeopleListStatus.of(browser) == .ready)
    }
}

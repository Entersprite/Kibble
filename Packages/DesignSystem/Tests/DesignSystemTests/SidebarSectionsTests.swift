import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The sidebar's grouping and ordering. Pure, so it is tested properly rather
/// than eyeballed - which is the reason it is not written inline in a view.
struct SidebarSectionsTests {
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    private func conversation(
        _ id: String,
        _ kind: Conversation.Kind,
        title: String? = nil,
        activity: TimeInterval? = nil
    ) -> Conversation {
        Conversation(
            id: Conversation.ID(id),
            kind: kind,
            title: title,
            lastActivity: activity.map { at.addingTimeInterval($0) }
        )
    }

    @Test func eachKindLandsInItsOwnSectionInAFixedOrder() {
        let sections = SidebarSections.build([
            conversation("space:1", .space, title: "eng"),
            conversation("dm:1", .directMessage),
            conversation("dm:2", .groupDirectMessage, title: "launch"),
            conversation("dm:3", .appDirectMessage, title: "deploybot")
        ])
        #expect(sections.map(\.title) == ["Direct messages", "Group chats", "Spaces", "Apps"])
    }

    @Test func anEmptySectionIsNotShown() {
        let sections = SidebarSections.build([conversation("space:1", .space, title: "eng")])
        #expect(sections.map(\.title) == ["Spaces"])
    }

    @Test func noConversationsMeansNoSections() {
        #expect(SidebarSections.build([]).isEmpty)
    }

    /// A conversation kind this build does not know gets its own section,
    /// headed by its raw token, rather than being guessed at or dropped.
    ///
    /// The fixture world ships a `.unknown("meetCall")` conversation precisely
    /// so this path is exercised on day one. Calling it "Meet" would be the UI
    /// asserting something the protocol work has not established - hence the
    /// heading is the token itself.
    ///
    /// This replaced a shared "Other" bucket on 2026-09-08, when the real
    /// account turned out to carry **187 of 220** conversations under one
    /// unrecognised group type (`findings.md` §37.4). One heading for the
    /// largest group in the sidebar said nothing useful about it.
    @Test func anUnknownKindGetsItsOwnSectionHeadedByItsToken() {
        let sections = SidebarSections.build([
            conversation("space:meet", .unknown("meetCall"), title: "Pricing standup")
        ])
        #expect(sections.map(\.title) == ["meetCall"])
        #expect(sections.first?.conversations.count == 1)
    }

    /// Two different unrecognised tokens are two sections, not one bucket -
    /// the whole point of the change. Sorted by token so the order is stable.
    @Test func twoUnrecognisedKindsAreTwoSections() {
        let sections = SidebarSections.build([
            conversation("space:a", .unknown("attributeCheckerGroupType10"), title: "a"),
            conversation("dm:b", .unknown("attributeCheckerGroupType11"), title: "b"),
            conversation("space:c", .space, title: "c")
        ])
        #expect(sections.map(\.title) == [
            "Spaces", "attributeCheckerGroupType10", "attributeCheckerGroupType11"
        ])
    }

    /// An empty token still needs a heading, so it keeps the "Other" bucket -
    /// a section titled with the empty string would render as a blank row.
    @Test func anEmptyUnknownTokenFallsBackToOther() {
        let sections = SidebarSections.build([
            conversation("space:x", .unknown(""), title: "x")
        ])
        #expect(sections.map(\.title) == ["Other"])
    }

    @Test func withinASectionTheMostRecentComesFirst() {
        let sections = SidebarSections.build([
            conversation("space:1", .space, title: "older", activity: 0),
            conversation("space:2", .space, title: "newer", activity: 60)
        ])
        #expect(sections.first?.conversations.map(\.title) == ["newer", "older"])
    }

    /// `lastActivity == nil` means "never, or not known yet" - which sorts
    /// below anything with a timestamp rather than being treated as the epoch.
    @Test func aConversationWithNoActivitySortsLast() {
        let sections = SidebarSections.build([
            conversation("space:1", .space, title: "quiet"),
            conversation("space:2", .space, title: "busy", activity: 0)
        ])
        #expect(sections.first?.conversations.map(\.title) == ["busy", "quiet"])
    }

    @Test func conversationsWithTheSameActivityAreOrderedStably() {
        let sections = SidebarSections.build([
            conversation("space:b", .space, title: "b", activity: 0),
            conversation("space:a", .space, title: "a", activity: 0)
        ])
        #expect(sections.first?.conversations.map(\.id.rawValue) == ["space:a", "space:b"])
    }

    @Test func sectionsCarryStableIdentitiesForSwiftUI() {
        let sections = SidebarSections.build([conversation("dm:1", .directMessage)])
        #expect(sections.first?.id == "directMessage")
    }

    /// The heading a conversation sits under and the section rule it obeys
    /// come from one mapping (`SectionKey(kind:)`), so they cannot disagree.
    @Test func everyHeadingIsTheTitleOfItsRuleSection() {
        let kinds: [Conversation.Kind] = [
            .directMessage,
            .groupDirectMessage,
            .space,
            .appDirectMessage,
            .meetChat
        ]
        for kind in kinds {
            let conversation = Conversation(id: Conversation.ID("x/\(kind)"), kind: kind, title: "t")
            let section = SidebarSections.build([conversation]).first
            #expect(section?.title == Display.title(of: SectionKey(kind: kind)), "\(kind)")
        }
    }
}

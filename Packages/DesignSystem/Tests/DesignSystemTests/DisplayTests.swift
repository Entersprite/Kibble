import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What a conversation and a person are called on screen.
struct DisplayTests {
    private let me = Member.ID("me")
    private let alice = Member.ID("alice")
    private let bob = Member.ID("bob")

    private var directory: [Member.ID: Member] {
        [
            me: Member(id: me, kind: .human, displayName: "Me"),
            alice: Member(id: alice, kind: .human, displayName: "Alice Adams"),
            bob: Member(id: bob, kind: .human, displayName: "Bob Brown"),
            Member.ID("app"): Member(id: Member.ID("app"), kind: .app)
        ]
    }

    @Test func aServerTitleIsUsedAsGiven() {
        let space = Conversation(id: Conversation.ID("space:1"), kind: .space, title: "price-engine")
        #expect(Display.title(of: space, directory: directory, me: me) == "price-engine")
    }

    /// A DM has no server-provided title, so one is derived from the people in
    /// it - excluding yourself, because a DM named after you is useless.
    @Test func aDirectMessageIsNamedAfterTheOtherPerson() {
        let dm = Conversation(
            id: Conversation.ID("dm:1"),
            kind: .directMessage,
            members: [me, alice]
        )
        #expect(Display.title(of: dm, directory: directory, me: me) == "Alice Adams")
    }

    @Test func aGroupIsNamedAfterEveryoneElse() {
        let group = Conversation(
            id: Conversation.ID("dm:2"),
            kind: .groupDirectMessage,
            members: [me, alice, bob]
        )
        #expect(Display.title(of: group, directory: directory, me: me) == "Alice Adams, Bob Brown")
    }

    /// An empty title is a title the server really sent, and is not the same as
    /// having none. Deriving over it would be overriding the server.
    @Test func anEmptyServerTitleIsRespectedRatherThanDerivedOver() {
        let space = Conversation(id: Conversation.ID("space:1"), kind: .space, title: "")
        #expect(Display.title(of: space, directory: directory, me: me) == "")
    }

    @Test func aConversationWithNobodyElseInItFallsBackToItsIdentifier() {
        let empty = Conversation(id: Conversation.ID("dm:9"), kind: .directMessage, members: [me])
        #expect(Display.title(of: empty, directory: directory, me: me) == "dm:9")
    }

    /// An app has no display name anywhere - the API returns only a name and a
    /// type, and there is no profile to look up - so the UI must not render a
    /// blank.
    @Test func anAppWithNoNameFallsBackToItsIdentifier() {
        #expect(Display.name(of: Member.ID("app"), in: directory) == "app")
    }

    @Test func someoneTheDirectoryHasNeverHeardOfStillRenders() {
        #expect(Display.name(of: Member.ID("ghost"), in: directory) == "ghost")
    }

    @Test func initialsComeFromTheDisplayName() {
        #expect(Display.initials(of: alice, in: directory) == "AA")
        #expect(Display.initials(of: Member.ID("app"), in: directory) == "AP")
    }
}

/// Avatar colours are derived from identifiers, so they must be derived the
/// same way in every process. Swift's `hashValue` is seeded per launch, which
/// would repaint everyone's avatar every time the app started.
struct AvatarPaletteTests {
    @Test func thePaletteIndexIsStableForAKnownIdentifier() {
        // Pinned values. If these change, the hash changed - and every user's
        // avatars change colour with it.
        #expect(AvatarPalette.index(for: "people/maya", count: 8) == 3)
        #expect(AvatarPalette.index(for: "people/dan", count: 8) == 6)
        // The empty string hashes to the FNV offset basis, 0xcbf29ce484222325,
        // whose low three bits are 5 - checkable by hand, which is what makes
        // this a pin on the algorithm rather than on whatever it printed today.
        #expect(AvatarPalette.index(for: "", count: 8) == 5)
    }

    @Test func theIndexIsAlwaysInsideThePalette() {
        for raw in ["a", "people/very-long-identifier-here", "🙂", "dm:1"] {
            let index = AvatarPalette.index(for: raw, count: 8)
            #expect((0 ..< 8).contains(index))
        }
    }

    @Test func theSameIdentifierAlwaysGivesTheSameIndex() {
        #expect(
            AvatarPalette.index(for: "people/alice", count: 8)
                == AvatarPalette.index(for: "people/alice", count: 8)
        )
    }
}

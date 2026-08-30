import Foundation
import Testing
@testable import ChatKit

/// Chat apps have no display name anywhere in the Chat API, and no People API
/// profile either — they are not Google accounts. A local alias is the only way
/// to make bot-heavy spaces readable, so alias precedence is worth pinning down.
@Suite("Display name resolution")
struct DisplayNameResolutionTests {
    @Test("a resolved directory name is used when there is no alias")
    func resolvedName() {
        let name = DisplayNameResolution.name(
            forUser: "users/1",
            aliases: [:],
            resolved: ["users/1": "Ada Lovelace"]
        )
        #expect(name == "Ada Lovelace")
    }

    @Test("a local alias overrides the directory name")
    func aliasWins() {
        let name = DisplayNameResolution.name(
            forUser: "users/1",
            aliases: ["users/1": "Ada"],
            resolved: ["users/1": "Ada Lovelace"]
        )
        #expect(name == "Ada")
    }

    @Test("an alias works where nothing else can resolve")
    func aliasOnly() {
        let name = DisplayNameResolution.name(
            forUser: "users/9000",
            aliases: ["users/9000": "Deploy Bot"],
            resolved: [:]
        )
        #expect(name == "Deploy Bot")
    }

    @Test("an unknown user resolves to nil so callers can show the id")
    func unknown() {
        #expect(DisplayNameResolution.name(forUser: "users/7", aliases: [:], resolved: [:]) == nil)
    }

    @Test("blank and whitespace-only aliases are ignored, not shown as empty names")
    func blankAliasIgnored() {
        #expect(
            DisplayNameResolution.name(
                forUser: "users/1", aliases: ["users/1": "   "], resolved: ["users/1": "Ada"]
            ) == "Ada"
        )
        #expect(
            DisplayNameResolution.name(
                forUser: "users/1", aliases: ["users/1": ""], resolved: [:]
            ) == nil
        )
    }

    @Test("aliases are trimmed")
    func trimsAlias() {
        #expect(
            DisplayNameResolution.name(
                forUser: "users/1", aliases: ["users/1": "  Deploy Bot \n"], resolved: [:]
            ) == "Deploy Bot"
        )
    }

    @Test("a blank resolved name falls through rather than rendering empty")
    func blankResolvedIgnored() {
        #expect(
            DisplayNameResolution.name(
                forUser: "users/1", aliases: [:], resolved: ["users/1": "  "]
            ) == nil
        )
    }
}

import Foundation
import Testing
@testable import ChatKit

struct ConversationManagementCodingTests {
    /// Block is a plain action with its own discriminator; a reader that
    /// predates it keeps the payload as `.unknown`.
    @Test func blockRoundTripsAsItsOwnAction() throws {
        let encoded = try JSONEncoder().encode(ConversationMutation.block)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded)
            == JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"block"}"#.utf8)))
        #expect(try JSONDecoder().decode(ConversationMutation.self, from: encoded) == .block)
        #expect(ConversationMutation.block.action == "block")
    }

    /// Absent lists are empty, so an answer that names no senders, or an
    /// older one, still decodes.
    @Test func previewsRoundTripAndDefaultToEmpty() throws {
        let message = Message(
            id: .init("m1"), conversationID: .init("space"), threadID: .init("t1"),
            sender: .init("u-1"), text: "Hello", createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let preview = ConversationPreview(
            messages: [message], members: [Member(id: .init("u-1"), kind: .human, displayName: "Ada")]
        )
        #expect(try JSONDecoder().decode(ConversationPreview.self, from: JSONEncoder().encode(preview))
            == preview)
        #expect(try JSONDecoder()
            .decode(ConversationPreview.self, from: Data("{}".utf8)) == ConversationPreview())
    }

    /// Advertised by name, so an older peer that never says it is assumed
    /// unable to preview.
    @Test func previewCapabilityIsAnExtendedFlag() {
        #expect(!Capabilities().canPreviewConversations)
        #expect(Capabilities(extendedFlags: ["conversationPreview"]).canPreviewConversations)
    }

    @Test func directoryQueriesDefaultToUnjoinedAndKeepOlderQueriesCompatible() throws {
        #expect(SpaceDirectoryQuery().scope == .discover)
        let old = try JSONDecoder().decode(
            SpaceDirectoryQuery.self,
            from: Data(#"{"scope":{"type":"joined"},"text":"query"}"#.utf8)
        )
        #expect(old.scope == .joined && old.organization == .all)
        let query = SpaceDirectoryQuery(scope: .all, text: "query", organization: .externalOnly)
        #expect(try JSONDecoder().decode(
            SpaceDirectoryQuery.self,
            from: JSONEncoder().encode(query)
        ) == query)
        let unfamiliar = Data(#"{"type":"partner","future":{"policy":true}}"#.utf8)
        let origin = try JSONDecoder().decode(SpaceDirectoryOrganization.self, from: unfamiliar)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(origin))
            == JSONDecoder().decode(JSONValue.self, from: unfamiliar))
    }

    @Test func sortDirectionDefaultsRemainCompatibleAndExplicitChoicesRoundTrip() throws {
        let old = SidebarSectionPreference(id: "space", sort: .name)
        let restored = try JSONDecoder().decode(
            SidebarSectionPreference.self,
            from: JSONEncoder().encode(old)
        )
        #expect(restored.sortsAscending)
        #expect(SidebarSectionPreference(id: "directMessage").sortsAscending == false)
        let descending = SidebarSectionPreference(id: "space", sort: .name, isAscending: false)
        #expect(try JSONDecoder().decode(
            SidebarSectionPreference.self,
            from: JSONEncoder().encode(descending)
        ) == descending)
    }

    @Test func savedThreeSectionPreferencesGainSeparateAppsAndMeetChats() throws {
        let saved = SidebarPreferences(sections: [
            .init(id: "space", maximumItems: 24, sort: .activity),
            .init(id: "directMessage", isVisible: false),
            .init(id: "groupDirectMessage")
        ])
        let restored = try JSONDecoder().decode(SidebarPreferences.self, from: JSONEncoder().encode(saved))
        #expect(restored.orderedSections.map(\.id) == [
            "space", "directMessage", "groupDirectMessage", "appDirectMessage", "meetChat"
        ])
        #expect(restored.orderedSections.first?.maximumItems == 24)
        #expect(restored.orderedSections[1].isVisible == false)
        #expect(restored.orderedSections.suffix(2).allSatisfy {
            $0.isVisible && $0.maximumItems == 10 && $0.sort == .activity
        })
    }

    @Test func favoritesDecodeOlderPreferencesAndPreserveSortChoices() throws {
        let old = try JSONDecoder().decode(SidebarPreferences.self, from: Data(#"{"sections":[]}"#.utf8))
        #expect(old.favoriteConversations.isEmpty && old.favoriteMeetings.isEmpty)
        var saved = SidebarPreferences(
            sections: [.init(id: "space"), .init(
                id: "favorites",
                isVisible: false,
                maximumItems: 1,
                sort: .name,
                isAscending: false
            )],
            favoriteConversations: [.init("opaque-chat")], favoriteMeetings: [.init("opaque-series")]
        )
        saved.update(.init(id: "appDirectMessage", isVisible: false))
        let restored = try JSONDecoder().decode(SidebarPreferences.self, from: JSONEncoder().encode(saved))
        #expect(restored == saved)
        #expect(restored.displaySections.first?.id == "favorites")
        #expect(restored.favoritesSection.isVisible)
        #expect(restored.favoritesSection.maximumItems == Int.max)
        #expect(restored.favoritesSection.sort == .name)
        #expect(!restored.favoritesSection.sortsAscending)
        #expect(restored.orderedSections.first?.id == "space")
        #expect(restored.favoriteConversations == [.init("opaque-chat")])
        #expect(restored.favoriteMeetings == [.init("opaque-series")])
    }

    @Test func unfamiliarRolesRetainTheirEntirePayload() throws {
        let data = Data(#"{"type":"moderator","permissions":{"future":true}}"#.utf8)
        let role = try JSONDecoder().decode(ConversationRole.self, from: data)
        #expect(role.type == "moderator")
        let original = try JSONDecoder().decode(JSONValue.self, from: data)
        let encoded = try JSONEncoder().encode(role)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == original)
    }

    @Test func unknownMutationsRetainNestedFields() throws {
        let data = Data(#"{"type":"futureAction","targets":[{"kind":"robot","id":"abc"}]}"#.utf8)
        let mutation = try JSONDecoder().decode(ConversationMutation.self, from: data)
        guard case .unknown = mutation else { Issue.record("Expected unknown mutation"); return }
        let encoded = try JSONEncoder().encode(mutation)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded)
            == JSONDecoder().decode(JSONValue.self, from: data))
    }

    @Test func oldCapabilitiesNeverEnableManagement() throws {
        let capabilities = try JSONDecoder().decode(Capabilities.self, from: Data("{}".utf8))
        #expect(!capabilities.canCreateConversations)
        #expect(!capabilities.canReadConversationDetails)
        #expect(!capabilities.canBrowseSpaces)
    }

    @Test func identityPatchPreservesAnExplicitClear() throws {
        let mutation = ConversationMutation.identity(name: nil, description: "", access: nil)
        let data = try JSONEncoder().encode(mutation)
        #expect(try JSONDecoder().decode(ConversationMutation.self, from: data) == mutation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] == nil)
        #expect(object["description"] as? String == "")
    }
}

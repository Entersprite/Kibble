import Foundation
import Testing
@testable import ChatKit

struct ConversationManagementCodingTests {
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

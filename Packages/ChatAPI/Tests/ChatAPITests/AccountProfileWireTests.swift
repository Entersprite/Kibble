import ChatAPI
import ChatKit
import Foundation
import Testing

struct AccountProfileWireTests {
    @Test func oldProfilesAndRemovalRequestsKeepConservativeDefaults() throws {
        let profile = try ServiceCodec.decode(AccountProfile.self, from: Data("{}".utf8))
        #expect(profile.displayName == nil && profile.email == nil && profile.organization == .unstated)
        #expect(try !ServiceCodec.decode(RemoveAccount.self, from: Data("{}".utf8)).forgetsSettings)
        let account = AccountSummary(
            id: .init("a"),
            selfID: .init("self"),
            label: "Legacy",
            connection: .idle
        )
        let roundtrip = try ServiceCodec.decode(AccountSummary.self, from: ServiceCodec.encode(account))
        #expect(roundtrip.profile == nil)
    }

    @Test func futureOrganizationRetainsEveryStructuredField() throws {
        let original = Data(#"{"type":"future","nested":{"level":7},"list":[true,"value"]}"#.utf8)
        let value = try ServiceCodec.decode(AccountOrganization.self, from: original)
        let decoded = try ServiceCodec.decode(JSONValue.self, from: ServiceCodec.encode(value))
        #expect(try decoded == ServiceCodec.decode(JSONValue.self, from: original))
        #expect(try ServiceCodec.decode(AccountOrganization.self, from: ServiceCodec.encode(value)) == value)
    }

    @Test func profileFieldsAreBoundedOnDecodeAsWellAsConstruction() throws {
        let profile = AccountProfile(
            displayName: "  Alex  ",
            email: String(repeating: "x", count: 513),
            organization: .managed(domain: "  example.invalid  ")
        )
        #expect(profile.displayName == "Alex" && profile.email == nil)
        #expect(profile.organization == .managed(domain: "example.invalid"))
        let encoded = try ServiceCodec.encode(["displayName": String(repeating: "x", count: 513)])
        #expect(try ServiceCodec.decode(AccountProfile.self, from: encoded).displayName == nil)
    }

    @Test func organizationGoldenShapesRemainStable() throws {
        let pairs: [(AccountOrganization, String)] = [
            (.personal, "organization-personal"), (.unstated, "organization-unstated"),
            (.managed(domain: "example.invalid"), "organization-managed")
        ]
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden")
        for (value, name) in pairs {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name)
                .appendingPathExtension("json"))
            let expected = try ServiceCodec.decode(JSONValue.self, from: bytes)
            #expect(try ServiceCodec.decode(JSONValue.self, from: ServiceCodec.encode(value)) == expected)
        }
    }
}

import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

extension SpaceSettingsBackendTests {
    @Test(arguments: [false, true])
    func joinRequestsUseTheNativePredicateAndRoleRecord(_ enabled: Bool) async throws {
        let transport = try SpaceSettingsTransport()
        if !enabled {
            await transport.beginDiscoverableWithJoinRequests()
        }
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .settings(.init(requestToJoin: enabled)), in: .init("space/a"),
            operationID: "request-predicate", expectedRevision: nil
        )
        #expect(result.isConfirmed && result.details?.settings?.requestToJoin == enabled)
        let request = try #require(await transport.updates.first)
        #expect(request.spacePermissions.rules.map(\.permission) == [22])
        let rule = try #require(request.spacePermissions.rules.first)
        let roles = try rule.roles.serializedData()
        for field in [1, 2, 3, 5, 6] {
            #expect(ProtoFieldScan.varintValues(ofField: field, in: roles) == [0])
        }
        if enabled {
            let predicate = try #require(rule.audiences.audiences.first)
            // Native UI creates type1, then its shared converter emits empty
            // name/ID and unspecified state. No selected target audience is used.
            #expect(try predicate.serializedData() == Data([0x0A, 0, 0x12, 2, 0x0A, 0, 0x18, 0, 0x20, 1]))
        } else {
            #expect(rule.audiences.audiences.isEmpty)
        }
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func wildcardJoinRequestsCanBeEditedWithoutASelectedDefaultAudience() async throws {
        let transport = try SpaceSettingsTransport()
        await transport.useWildcardJoinRequests()
        await transport.omitAudience()
        let backend = try await connected(transport)
        let before = try await backend.conversationDetails(.init("space/a"))
        #expect(before.settings?.requestToJoin == true)
        #expect(before.settings?.canChangeRequestToJoin == true)
        for enabled in [false, true] {
            let result = try await backend.mutateConversation(
                .settings(.init(requestToJoin: enabled)), in: .init("space/a"),
                operationID: "wildcard-\(enabled)", expectedRevision: nil
            )
            #expect(result.isConfirmed && result.details?.settings?.requestToJoin == enabled)
            #expect(result.details?.settings?.canChangeRequestToJoin == true)
        }
        #expect(await transport.updates.count == 2)
        await backend.disconnect()
    }

    @Test func standardAccessPresetsRetainTheReturnedAudienceMetadata() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .settings(.init(access: .open)), in: .init("space/a"),
            operationID: "audience-reference", expectedRevision: "1"
        )
        #expect(result.isConfirmed && result.details?.access == .open)
        let request = try #require(await transport.updates.first)
        #expect(request.spacePermissions.rules.map(\.permission) == [25, 24])
        for rule in request.spacePermissions.rules {
            let audience = try #require(rule.audiences.audiences.first)
            #expect(audience.id.id == "organization-audience")
            #expect(audience.name == "Example organization")
            // Standard presets use the returned default audience. Only custom native
            // access rebuilds references with unspecified state and classification.
            #expect(audience.hasState && audience.state == 1)
            #expect(audience.hasType && audience.type == 1)
        }
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }
}

extension SpaceSettingsTransport {
    func useWildcardJoinRequests() {
        guard let index = group.spacePermissions.rules.firstIndex(where: { $0.permission == 22 })
        else { return }
        var predicate = SpacePermissionAudience(); predicate.type = 1
        group.spacePermissions.rules[index].audiences.audiences = [predicate]
    }
}

import ChatKit
import Foundation
import GChatBridgeCore

/// Only protocol structure and redacted error information may reach a diagnostics report.
public struct ManagementWriteObservation: Codable, Sendable, Equatable {
    public let stage: String
    public var request: ManagementSettingsRequestShape?
    public var refusal: ManagementRefusalObservation?

    init(stage: String) {
        self.stage = stage
    }
}

public struct ManagementSettingsRequestShape: Codable, Sendable, Equatable {
    public let updateMasks: [Int]
    public let policies: [ManagementPolicyShape]
    public let defaultAudienceCount: Int
    public let canChangeAccess: Bool
    public let canChangeRequestToJoin: Bool
    public let wireFields: [String]?
    public let groupReferenceFields: [String]?
    public let clientFeatureLevels: [Int: Int]?

    init(_ request: UpdateGroupRequest, snapshot: GetGroupResponse, context: ManagementWriteContext) {
        updateMasks = request.updateMasks.map { Int($0.rawValue) }
        let features = (try? request.requestHeader.clientFeatureCapabilities.serializedData()) ?? Data()
        clientFeatureLevels = Dictionary(uniqueKeysWithValues: [10, 37, 56, 64, 70].compactMap { field in
            guard let value = ProtoFieldScan.varintValues(ofField: field, in: features).first, value <= 2
            else { return nil }
            return (field, Int(value))
        })
        wireFields = (try? request.serializedData()).map(Self.fields)
        groupReferenceFields = (try? request.groupID.serializedData()).map(Self.fields)
        policies = request.spacePermissions.rules.map { ManagementPolicyShape(
            $0,
            defaults: snapshot.defaultTargetAudiences
        ) }
        defaultAudienceCount = snapshot.defaultTargetAudiences.count
        canChangeAccess = context.before.settings?.canChangeAccess ?? false
        canChangeRequestToJoin = context.before.settings?.canChangeRequestToJoin ?? false
    }

    private static func fields(_ data: Data) -> [String] {
        ProtoFieldScan.fields(in: data).fields.map { "\($0.number)/\($0.wireType)/\($0.byteCount)" }
    }
}

public struct ManagementPolicyShape: Codable, Sendable, Equatable {
    public let number: Int
    public let roles: [Int: Bool]
    public let audienceCount: Int
    public let defaultAudienceMatches: Int
    public let unknownRoleFields: [Int]
    public let audienceWireFields: [[String]]?
    public let audienceStates: [Int]?
    public let audienceClassifications: [Int]?

    init(_ rule: SpacePermissionRule, defaults: [SpacePermissionAudience]) {
        number = Int(rule.permission)
        var flags = [
            1: rule.roles.owners,
            2: rule.roles.members,
            3: rule.roles.organization,
            6: rule.roles.managers
        ]
        if let flag = ProtoFieldScan.varintValues(ofField: 5, in: rule.roles.unknownFields.data).last {
            flags[5] = flag != 0
        }
        roles = flags
        audienceCount = rule.audiences.audiences.count
        audienceStates = rule.audiences.audiences.map { Int($0.state) }
        audienceClassifications = rule.audiences.audiences.map { Int($0.type) }
        audienceWireFields = rule.audiences.audiences.compactMap { audience in
            (try? audience.serializedData()).map { data in
                ProtoFieldScan.fields(in: data).fields.map { "\($0.number)/\($0.wireType)/\($0.byteCount)" }
            }
        }
        defaultAudienceMatches = rule.audiences.audiences.filter { audience in
            defaults.contains { $0.id == audience.id }
        }.count
        unknownRoleFields =
            Array(Set(ProtoFieldScan.fields(in: rule.roles.unknownFields.data).fields.map(\.number))).sorted()
    }
}

extension LocalBridgeBackend {
    func recordManagementStage(_ step: String, failure: String?) {
        diagnostics.record(.managementWrite(step: step, failure: failure))
        var value = ConversationActionObservation(
            rpc: "conversation_management", status: nil, serviceCode: nil, outcome: failure ?? "ok"
        )
        value.management = ManagementWriteObservation(stage: step)
        onConversationAction?(value)
    }

    func sendSettingsRequest(
        _ request: UpdateGroupRequest, snapshot: GetGroupResponse, context: ManagementWriteContext
    ) async throws -> UpdateGroupResponse {
        var detail = ManagementWriteObservation(stage: "settingsRequest")
        detail.request = ManagementSettingsRequestShape(request, snapshot: snapshot, context: context)
        let observation = detail
        let record = onConversationAction
        let sensitive = snapshot.defaultTargetAudiences.flatMap { [$0.id.id, $0.name] }
            + [
                context.before.conversation.title ?? "",
                context.me.rawValue,
                context.group.spaceID.spaceID,
                context.group.dmID.dmID
            ]
        do {
            let response = try await context.client.call(.updateGroup, request, onRefusal: { refusal in
                var failed = observation
                failed.refusal = ManagementRefusalObservation(refusal.body, sensitive: sensitive)
                var event = ConversationActionObservation(
                    rpc: "update_group", status: refusal.status,
                    serviceCode: failed.refusal?.code, outcome: "httpRefusal"
                )
                event.management = failed
                record?(event)
            })
            var event = ConversationActionObservation(
                rpc: "update_group",
                status: 200,
                serviceCode: nil,
                outcome: "ok"
            )
            event.management = detail
            record?(event)
            return response
        } catch {
            if case .httpStatus = error as? APIFailure {
                throw error
            }
            var event = ConversationActionObservation(
                rpc: "update_group", status: nil, serviceCode: nil, outcome: ManagementFailureKind.of(error)
            )
            event.management = detail
            record?(event)
            throw error
        }
    }
}

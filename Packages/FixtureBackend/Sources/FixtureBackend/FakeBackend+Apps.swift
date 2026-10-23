import ChatKit
import Foundation

public extension FakeBackend {
    func openAppConversation(_ app: Member.ID, from id: Conversation.ID) async throws -> Conversation {
        let listing = try await conversationIntegrations(id)
        guard listing.apps.contains(where: { $0.id == app }) else {
            throw ChatError.unsupported(capability: "conversationApp")
        }
        if let existing = world.conversations
            .first(where: { $0.kind == .appDirectMessage && $0.members.contains(app) }) {
            return existing
        }
        let conversation = Conversation(
            id: .init(nextIdentifier("fixture-app-dm")), kind: .appDirectMessage, members: [world.me, app]
        )
        world.conversations.append(conversation)
        if let member = Self.appCatalog.first(where: { $0.id == app })?.member, world.member(app) == nil {
            world.members.append(member)
        }
        emit(.conversationUpdated(conversation))
        return conversation
    }

    func searchConversationApps(_ query: String, in id: Conversation.ID) async throws -> [ConversationApp] {
        try require(capabilities.canManageConversationApps, "conversationApps")
        let details = try await conversationDetails(id)
        guard details.allowedActions.contains("addApp") else {
            throw ChatError.unsupported(capability: "conversationApps")
        }
        let installed = Set((managedApps[id] ?? []).map(\.id))
        return Self.appCatalog.filter {
            !installed.contains($0.id) && (query.isEmpty || ($0.member.displayName ?? "")
                .localizedCaseInsensitiveContains(query))
        }
    }
}

extension FakeBackend {
    static var appCatalog: [ConversationApp] {
        ["Poll", "Build Monitor", "Issue Tracker"].enumerated().map { offset, name in
            ConversationApp(
                member: Member(id: .init("fixture-app-\(offset)"), kind: .app, displayName: name),
                description: "An app for your conversation.", allowedActions: ["addApp"]
            )
        }
    }

    func changeManagedApps(_ mutation: ConversationMutation, in id: Conversation.ID) throws {
        try require(capabilities.canManageConversationApps, "conversationApps")
        var apps = managedApps[id] ?? []
        switch mutation {
        case let .addApp(app):
            guard var value = Self.appCatalog.first(where: { $0.id == app }),
                  !apps.contains(where: { $0.id == app }) else {
                throw ChatError.unsupported(capability: "conversationApp")
            }
            value.allowedActions = ["message", "removeApp"]
            apps.append(value)
        case let .removeApp(app):
            guard apps.contains(where: { $0.id == app }) else {
                throw ChatError.unsupported(capability: "conversationApp")
            }
            apps.removeAll { $0.id == app }
        default: throw ChatError.unsupported(capability: "conversationApps")
        }
        managedApps[id] = apps
    }
}

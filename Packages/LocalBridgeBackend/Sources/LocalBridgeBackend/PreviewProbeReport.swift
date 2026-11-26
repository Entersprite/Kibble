import ChatKit
import Foundation
import GChatBridgeCore
import os
import URLSessionTransport

/// `--probe=preview`: whether a space the account has not joined can be read,
/// and whether other people's Do not disturb carries its end.
///
/// **Reads only.** `list_invited_rooms`, `search_space_directory`,
/// `get_group`, `list_topics`, `list_messages` and `get_user_presence`; nothing
/// is joined, blocked, marked or posted. Every line is a count, a boolean, a
/// status or an enum, never an id, a name or message text, so each is also
/// written to the unified log, the one place a sandboxed run writes that a
/// terminal can read.
public enum PreviewProbeReport {
    /// How many spaces of each kind are read, at most.
    static let spacesPerKind = 3

    public static func run(
        store: KeychainCredentialStore, expectedSelfID: ChatKit.Member.ID,
        transport: any HTTPTransport = URLSessionTransport(), endpoints: ChatEndpoints = .init()
    ) async -> String {
        var lines = ["preview read probe"]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let prepared = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              ) else { return finish(lines) }
        let client = ProtoAPIClient(
            transport: transport, endpoints: endpoints,
            credentials: prepared.credentials, xsrfToken: prepared.wiz.xsrfToken
        )
        do {
            let me = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            guard me.userStatus.userID.id == expectedSelfID.rawValue else {
                return finish(["Stopped: the saved account identity changed."])
            }
            let world = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            lines.append("world: groups=\(world.worldItems.count)")
            await appendSpaces(client: client, world: world, lines: &lines)
            await appendDoNotDisturb(client: client, world: world, me: expectedSelfID.rawValue, lines: &lines)
        } catch {
            lines.append("FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        return finish(lines)
    }

    private static func finish(_ lines: [String]) -> String {
        let logger = Logger(subsystem: "com.entersprite.kibble", category: "preview-probe")
        for line in lines {
            logger.notice("\(line, privacy: .public)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Spaces not joined

    private static func appendSpaces(
        client: ProtoAPIClient, world: PaginatedWorldResponse, lines: inout [String]
    ) async {
        let joined = Set(world.worldItems.map(\.groupID))
        var invited: [GroupId] = []
        do {
            let response = try await client.call(
                .listInvitedRooms,
                ConversationManagementRequests.invitations()
            )
            invited = response.invitations.map(\.groupID).filter { !joined.contains($0) }
            lines.append("invitations: rows=\(response.invitations.count) notInWorld=\(invited.count)")
        } catch {
            lines.append("invitations FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        for (index, group) in invited.prefix(spacesPerKind).enumerated() {
            await appendSpace(group, label: "invited \(index)", client: client, lines: &lines)
        }
        var discoverable: [GroupId] = []
        do {
            let response = try await client.call(
                .searchSpaceDirectory, ConversationManagementRequests.discover("", token: nil)
            )
            discoverable = response.spaces.filter {
                $0.membershipState != .memberJoined && $0.membershipState != .memberInvited
                    && !joined.contains($0.groupID) && !invited.contains($0.groupID)
            }.map(\.groupID)
            let states = Dictionary(grouping: response.spaces, by: { "\($0.membershipState)" })
                .mapValues(\.count)
            lines.append(
                "directory not joined: rows=\(response.spaces.count) candidates=\(discoverable.count) "
                    + "summaryStates=\(states.sorted { $0.key < $1.key })"
            )
            var groupStates: [String: Int] = [:]
            for group in discoverable.prefix(12) {
                let state = try? await client.call(
                    .managementDetails, ConversationManagementRequests.details(group)
                ).membershipState
                groupStates[state.map { "\($0)" } ?? "failed", default: 0] += 1
            }
            lines.append("directory get_group states (first 12)=\(groupStates.sorted { $0.key < $1.key })")
            let spam = try? await client.call(
                .listInvitedRooms,
                ConversationManagementRequests.invitations(spam: true)
            )
            lines.append("spam invitations: rows=\(spam.map { "\($0.invitations.count)" } ?? "failed")")
        } catch {
            lines.append("directory FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        for (index, group) in discoverable.prefix(spacesPerKind).enumerated() {
            await appendSpace(group, label: "discoverable \(index)", client: client, lines: &lines)
        }
    }

    private static func appendSpace(
        _ group: GroupId, label: String, client: ProtoAPIClient, lines: inout [String]
    ) async {
        do {
            let response = try await client.call(
                .managementDetails,
                ConversationManagementRequests.details(group)
            )
            let snippet = response.snippet
            lines.append("\(label) get_group: OK state=\(response.membershipState) "
                + "snippet=\(response.hasSnippet) snippetText=\(!snippet.textBody.isEmpty) "
                + "snippetSender=\(!snippet.creator.userID.id.isEmpty)")
        } catch {
            lines.append("\(label) get_group FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        var firstTopic: TopicId?
        do {
            let response = try await client.call(.listTopics, TopicsRequestLadder.history(for: group).request)
            let messages = response.topics.flatMap(\.replies)
            firstTopic = response.topics.first { !$0.replies.isEmpty }?.id
            let lastTopic = response.hasContainsLastTopic ? "\(response.containsLastTopic)" : "absent"
            lines.append("\(label) list_topics: OK topics=\(response.topics.count) "
                + "messages=\(messages.count) withText=\(messages.count { !$0.textBody.isEmpty }) "
                + "withSender=\(messages.count { !$0.creator.userID.id.isEmpty }) "
                + "mapped=\(HistoryMapping.map(response).messages.count) lastTopicFlag=\(lastTopic)")
        } catch {
            lines.append("\(label) list_topics FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        guard let firstTopic else { return }
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID = firstTopic
        request.pageSize = 10
        do {
            let response = try await client.call(.listMessages, request)
            lines.append("\(label) list_messages: OK messages=\(response.messages.count) "
                + "withText=\(response.messages.count { !$0.textBody.isEmpty }) "
                + "withSender=\(response.messages.count { !$0.creator.userID.id.isEmpty })")
        } catch {
            lines.append("\(label) list_messages FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
    }

    // MARK: - Other people's Do not disturb

    private static func appendDoNotDisturb(
        client: ProtoAPIClient, world: PaginatedWorldResponse, me: String, lines: inout [String]
    ) async {
        let partners = Set(world.worldItems.filter { WorldMapping.kind(for: $0) == .directMessage }
            .flatMap { $0.dmMembers.members.map(\.id) }
            .filter { !$0.isEmpty && $0 != me })
        let ids = partners.sorted().prefix(200).map { ChatKit.Member.ID($0) }
        lines.append("dm partners asked: \(ids.count)")
        guard !ids.isEmpty else { return }
        do {
            let response = try await client.call(
                .getUserPresence, LocalBridgeBackend.getUserPresenceRequest(Array(ids))
            )
            lines += doNotDisturbLines(response, now: Date())
        } catch {
            lines.append("get_user_presence FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
    }

    static func doNotDisturbLines(_ response: GetUserPresenceResponse, now: Date) -> [String] {
        let entries = response.userPresences
        let inDnd = entries.filter { PresenceMapping.presence(of: $0) == .doNotDisturb }
        let settings = inDnd.filter(\.userStatus.hasDndSettings).map(\.userStatus.dndSettings)
        let nowMicros = Int64(now.timeIntervalSince1970 * 1_000_000)
        let expiry = settings.filter { $0.hasDndExpiryTimeUsec && $0.dndExpiryTimeUsec > 0 }
        let remaining = settings
            .filter { $0.hasStateRemainingDurationUsec && $0.stateRemainingDurationUsec > 0 }
        let drift = settings.filter { expiry.contains($0) && remaining.contains($0) }.map {
            ($0.dndExpiryTimeUsec - nowMicros - $0.stateRemainingDurationUsec) / 1_000_000
        }
        let staleExpiry = entries.count { entry in
            PresenceMapping.presence(of: entry) != .doNotDisturb
                && entry.userStatus.dndSettings.dndExpiryTimeUsec > 0
        }
        return [
            "presence entries=\(entries.count) inDnd=\(inDnd.count) "
                + "topLevelDnd=\(inDnd.count { $0.hasDndState && $0.dndState == .dnd }) "
                + "statusDnd=\(settings.count { $0.hasDndState && $0.dndState == .dnd })",
            "dnd settings present=\(settings.count) expiryPresent=\(expiry.count) "
                + "expiryAhead=\(expiry.count { $0.dndExpiryTimeUsec > nowMicros }) "
                + "remainingPresent=\(remaining.count) "
                + "bothPresent=\(settings.count { expiry.contains($0) && remaining.contains($0) }) "
                + "expiryMinusRemainingSeconds=\(drift) "
                + "unnamedBytes=\(settings.map(\.unknownFields.data.count).reduce(0, +))",
            "not in dnd but with expiry=\(staleExpiry)"
        ]
    }
}

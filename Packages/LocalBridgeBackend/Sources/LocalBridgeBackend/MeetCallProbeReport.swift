import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// `--probe=meet-resolve`: checks the Meet bootstrap and resolves one human DM.
/// It deliberately never calls `CreateMeetingInvite` or opens a browser. The
/// report carries only status, field lengths and the selected world index.
public enum MeetCallProbeReport {
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        conversation: ProbeConversation = .mostRecentDirectMessage
    ) async -> String {
        var lines = ["kibble Meet DM resolve probe (no ring, no browser)", ""]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let bootstrapped = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              )
        else { return lines.joined(separator: "\n") }
        let chat = ProtoAPIClient(
            transport: transport, endpoints: endpoints,
            credentials: bootstrapped.credentials, xsrfToken: bootstrapped.wiz.xsrfToken
        )
        guard let dmID = await chosenDM(client: chat, choice: conversation, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        if let meet = URL(string: "https://meet.google.com/"),
           let currentCookies = await bootstrapped.credentials.snapshot {
            let scoped = currentCookies.cookies.count { $0.isSent(to: meet) }
            let hostOnly = currentCookies.cookies.count { $0.domain?.lowercased() == "meet.google.com" }
            lines.append("Meet cookie scope: \(scoped) sent; \(hostOnly) Meet-host-only")
        }

        guard let configuration = await meetConfiguration(
            transport: transport, credentials: bootstrapped.credentials,
            endpoints: endpoints, lines: &lines
        ) else { return lines.joined(separator: "\n") }

        await appendResolve(
            dmID: dmID, configuration: configuration,
            transport: transport, credentials: bootstrapped.credentials, lines: &lines
        )
        return lines.joined(separator: "\n")
    }

    private static func meetConfiguration(
        transport: any HTTPTransport,
        credentials: SessionCredentials,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> MeetCallConfiguration? {
        let accountIndex = switch endpoints.account {
        case let .index(index): index
        case .none: 0
        }
        do {
            let configuration = try await MeetCallBootstrap(
                transport: transport, credentials: credentials
            ).loadConfiguration(accountIndex: accountIndex, userAgent: endpoints.userAgent)
            lines.append("Meet call shell: client key found")
            return configuration
        } catch let error as MeetCallBootstrapError {
            switch error {
            case let .redirected(status, target):
                lines.append("Meet call shell: HTTP \(status), redirect \(redirectLabel(target))")
            case let .httpStatus(status): lines.append("Meet call shell: HTTP \(status)")
            case .missingClientKey: lines.append("Meet call shell: no unique repeated client key")
            case .invalidRTCClientMetadata: lines.append("Meet call shell: invalid RTC client metadata")
            }
        } catch {
            lines.append("Meet call shell: \(type(of: error))")
        }
        return nil
    }

    private static func redirectLabel(_ target: MeetCallRedirect) -> String {
        switch target {
        case .accounts: "to Google sign-in"
        case .meet: "within Meet"
        case .otherGoogle: "to another Google host"
        case .elsewhere: "to an external host"
        case .unknown: "without a usable Location"
        }
    }

    private static func appendResolve(
        dmID: String,
        configuration: MeetCallConfiguration,
        transport: any HTTPTransport,
        credentials: SessionCredentials,
        lines: inout [String]
    ) async {
        do {
            let result = try await MeetCallClient(
                transport: transport, credentials: credentials, configuration: configuration, sha1: SHA1.hex
            ).resolve(dmID: dmID)
            lines.append("ResolveForHangoutsChat: accepted")
            lines.append(
                "  space name \(result.space.name.count) chars; "
                    + "meeting code \(result.space.code.count) chars"
            )
            lines.append("  normal Meet URL: valid meet.google.com link (value withheld)")
        } catch let error as MeetCallClientError {
            switch error {
            case let .httpStatus(status, refusal):
                lines.append("ResolveForHangoutsChat: HTTP \(status); \(refusal.safeDescription)")
            case .missingSessionProof:
                lines.append("ResolveForHangoutsChat: no scoped Google session proof; request not sent")
            case .missingMeetingToken: lines.append("ResolveForHangoutsChat: missing meeting token")
            case .inviteRejected: lines.append("ResolveForHangoutsChat: unexpected invite rejection")
            }
        } catch {
            lines.append("ResolveForHangoutsChat: \(type(of: error))")
        }
    }

    private static func chosenDM(
        client: ProtoAPIClient, choice: ProbeConversation, lines: inout [String]
    ) async -> String? {
        let response: PaginatedWorldResponse
        do {
            response = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
        } catch {
            lines.append("paginated_world: \(APIProbeReport.safeDescription(of: error))")
            return nil
        }
        let conversations = WorldMapping.map(response).conversations
        guard let index = APIProbeReport.chooseConversationIndex(
            conversations, choice: choice, lines: &lines
        ), let id = dmID(for: conversations[index])
        else {
            lines.append("Stopping: selected conversation is not a human DM.")
            return nil
        }
        lines.append("Selected human DM at world index \(index).")
        return id
    }

    /// Use the bridge's proven inverse of `conversationID` rather than parsing
    /// the domain prefix here. The on-wire DM id has no `dm/` prefix.
    static func dmID(for conversation: Conversation) -> String? {
        guard conversation.kind == .directMessage,
              let group = ChannelEventMapping.groupID(for: conversation.id),
              !group.dmID.dmID.isEmpty
        else { return nil }
        return group.dmID.dmID
    }
}

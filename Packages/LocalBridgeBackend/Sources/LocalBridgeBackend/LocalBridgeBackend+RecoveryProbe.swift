import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// Read-only provider recovery diagnostics. Reports contain counts, never event contents or revisions.
public enum ProviderRecoveryProbeReport {
    public static func run(
        store: KeychainCredentialStore, expectedSelfID: ChatKit.Member.ID,
        transport: any HTTPTransport = URLSessionTransport(), endpoints: ChatEndpoints = .init()
    ) async -> String {
        var lines = ["provider recovery read probe"]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let prepared = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              ) else { return lines.joined(separator: "\n") }
        let client = ProtoAPIClient(
            transport: transport, endpoints: endpoints,
            credentials: prepared.credentials, xsrfToken: prepared.wiz.xsrfToken
        )
        do {
            let me = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            guard me.userStatus.userID.id == expectedSelfID.rawValue else {
                return "Stopped: the saved account identity changed."
            }
            let world = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            lines.append("world: user revision present=\(world.userRevision.timestamp > 0), "
                + "groups=\(world.worldItems.count)")
            await probeUser(world, using: client, lines: &lines)
            await probeGroup(world, using: client, lines: &lines)
        } catch {
            lines.append("FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        return lines.joined(separator: "\n")
    }

    private static func probeUser(
        _ world: PaginatedWorldResponse, using client: ProtoAPIClient, lines: inout [String]
    ) async {
        let end = world.userRevision.timestamp
        guard end > 0 else { return }
        do {
            let response = try await client.call(
                .catchUpUser, CatchUpRequests.user(from: max(1, end - 120_000_000), through: end)
            )
            lines.append(summary(response, scope: "user"))
        } catch { lines.append("user catch-up FAILED: \(APIProbeReport.safeDescription(of: error))") }
    }

    private static func probeGroup(
        _ world: PaginatedWorldResponse, using client: ProtoAPIClient, lines: inout [String]
    ) async {
        guard let item = world.worldItems.filter({ WorldMapping.isVisible($0) })
            .max(by: { $0.groupRevision.timestamp < $1.groupRevision.timestamp }),
            item.groupRevision.timestamp > 0
        else { lines.append("group catch-up: no revision available"); return }
        let end = item.groupRevision.timestamp
        do {
            let response = try await client.call(.catchUpGroup, CatchUpRequests.group(
                item.groupID, from: max(1, end - 120_000_000), through: end
            ))
            lines.append(summary(response, scope: "group"))
        } catch { lines.append("group catch-up FAILED: \(APIProbeReport.safeDescription(of: error))") }
    }

    static func summary(_ response: CatchUpResponse, scope: String) -> String {
        let revised = response.events.filter { $0.revisionType != nil }.count
        let primary = response.events.filter(\.hasBody).count
        return "\(scope) catch-up: status=\(response.status.rawValue) events=\(response.events.count) "
            + "revisions=\(revised) primaryBodies=\(primary)"
    }
}

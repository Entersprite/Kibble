import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// `--probe=organization`: does Chat say who manages the signed-in account?
///
/// `get_self_user_status` for the account's own id, then one `get_members` of
/// that id, both reads. Reports whether the returned `User` carries
/// `organization_info` (field 12) and which kind it is.
///
/// **Presence, kinds and lengths, never a value**, the api probe's rule: no
/// id, email, domain or customer id is printed.
public enum OrganizationProbeReport {
    /// Every parameter defaults, so `MacHost` names no core type.
    public static func run(
        store: KeychainCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        flush: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> String {
        var lines = header()
        func done() -> String {
            let text = lines.joined(separator: "\n")
            flush(text)
            return text
        }
        flush(lines.joined(separator: "\n"))
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines) else {
            return done()
        }
        guard let bootstrapped = await APIProbeReport.appendBootstrap(
            cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
        ) else { return done() }
        flush(lines.joined(separator: "\n"))
        let api = ProtoAPIClient(
            transport: transport,
            endpoints: endpoints,
            credentials: bootstrapped.credentials,
            xsrfToken: bootstrapped.wiz.xsrfToken
        )
        var selfUserID: String?
        guard await APIProbeReport.appendVerifiedCall(client: api, selfUserID: &selfUserID, lines: &lines),
              let selfUserID
        else { return done() }
        lines.append("")
        lines.append("get_members of the account's own id:")
        flush(lines.joined(separator: "\n"))
        do {
            let response = try await api.call(
                .getMembers, LocalBridgeBackend.getMembersRequest([ChatKit.Member.ID(selfUserID)])
            )
            let users = response.members.map(\.user)
            lines.append("  OK - \(response.members.count) member(s)")
            guard let user = users.first(where: { $0.userID.id == selfUserID }) else {
                lines.append("  the account's own user is not among them")
                return done()
            }
            lines.append(contentsOf: describe(user))
        } catch {
            lines.append("  FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        return done()
    }

    static func describe(_ user: User) -> [String] {
        var lines = ["  email: \(user.email.isEmpty ? "absent" : "present")"]
        guard user.hasOrganizationInfo else {
            lines.append("  organization_info: absent")
            lines.append("  other unknown User fields: \(user.unknownFields.data.count) bytes")
            return lines
        }
        let info = user.organizationInfo
        lines.append("  organization_info: present")
        lines.append("    consumer_info: \(info.hasConsumerInfo ? "present" : "absent")")
        lines.append("    customer_info: \(info.hasCustomerInfo ? "present" : "absent")")
        if info.hasCustomerInfo {
            let customer = info.customerInfo.customerID.customerID
            lines.append("    customer id: \(customer.isEmpty ? "empty" : "\(customer.count) characters")")
            let extra = info.customerInfo.unknownFields.data.count
            lines.append("    other customer_info fields: \(extra) bytes")
        }
        lines.append("    other organization_info fields: \(info.unknownFields.data.count) bytes")
        return lines
    }

    /// The config row `CLAUDE.md` asks every trace for.
    static func header() -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return ["kibble organization probe", "config: build \(version) (\(build))", ""]
    }
}

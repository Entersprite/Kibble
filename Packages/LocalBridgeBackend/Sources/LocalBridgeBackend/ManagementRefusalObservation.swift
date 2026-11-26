import Foundation
import GChatBridgeCore

/// Extract a bounded status message, never headers, arbitrary details, or a raw response body.
public struct ManagementRefusalObservation: Codable, Sendable, Equatable {
    public let bodyBytes: Int
    public let format: String
    public let code: Int?
    public let message: String?
    public let wireShape: [String]?
    public let statusValues: [String: Int]?

    init(_ body: Data, sensitive: [String]) {
        bodyBytes = body.count
        let parsed = ManagementRefusalDecoder.decode(body)
        format = parsed.format
        code = parsed.code
        statusValues = parsed.statusValues.isEmpty ? nil : parsed.statusValues
        wireShape = parsed.wireShape.isEmpty ? nil : parsed.wireShape
        message = parsed.message.map { ManagementDiagnosticRedaction.redact($0, sensitive: sensitive) }
    }
}

/// Unknown words are withheld too: an error may echo a title or an account identifier
/// that was not in this request. The export keeps only a fixed technical vocabulary.
enum ManagementDiagnosticRedaction {
    private static let allowed = Set((
        "a an the this that these those is are was were be been being can cannot cant could not must "
            + "may only no none and or for from to of in on with without by as at if then than all any "
            + "has have had do does did should will would its it into between within before after "
            + "invalid argument arguments bad request requests error failed failure status code "
            + "parse parsing proto protobuf payload data credential credentials authentication authenticated "
            + "unauthenticated xsrf header headers client version feature capabilities malformed "
            + "permission permissions role roles owner owners manager managers member members "
            + "organization organisational organizational external internal guest guests user users "
            + "space spaces group groups audience audiences target targets default supported unsupported "
            + "allow allowed allows allowing deny denied disabled enabled enable disable find join "
            + "discover discoverable discoverability joinability private public open restricted "
            + "access settings setting update updates updated updating change changes changed changing "
            + "modify modified modifying edit editing empty missing required expected unexpected "
            + "value values field fields rule rules mask masks unknown unrecognized "
            + "malformed valid validation "
            + "set unset clear cleared contains contain include includes exclude excludes true false "
            + "must_not cannot_be_updated not_allowed invalid_argument failed_precondition permission_denied "
            + "space_permissions space_access space_access_settings space_access_config update_masks "
            + "group_id space_id membership_id target_audience target_audiences audience_id "
            + "request_to_join request_to_join_permission membership visibility history "
            + "space_permission_type_find_space space_permission_type_join_space "
            + "space_permission_type_request_to_join_space space_permission_type_view_members "
            + "space_permission_type_add_members space_permission_type_manage_members "
            + "space_access_type_private space_access_type_discoverable space_access_type_open "
            + "find_space join_space request_to_join_space invalidarg badrequest "
            + "spacepermissions spaceaccess spaceaccesssettings updatemasks groupid spaceid targetaudience "
            + "invalid_token invalid_proto invalid_input invalid_value invalid_param invalid_group "
            + "invalid_state invalid_owner invalid_mask invalid_grant invalid_request invalid_xsrf_token "
            + "bad_request unimplemented request_error bad_parameter parse_failure auth_required "
            + "not_authorized not_found already_exists session_expired internal_error server_error "
            + "access_denied permission_denied failed_precondition unauthenticated resource_exhausted "
            + "1 2 3 4 5 6 7 8 9 20 21 22 23 24 25 26 400 403 409"
    ).split(separator: " ").map(String.init))

    static func redact(_ message: String, sensitive: [String]) -> String {
        var text = String(message.prefix(2048))
        for value in sensitive.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            let boundary = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: value)
                + "(?![A-Za-z0-9_])"
            text = text.replacingOccurrences(
                of: boundary, with: "[redacted]", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|[A-Z][A-Z0-9+.-]*://[^\s]+"#,
            with: "[redacted]", options: .regularExpression
        )
        guard let pattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9_]+|[^\s]"#)
        else { return "[redacted]" }
        let source = text as NSString
        let tokens = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { match in
                let token = source.substring(with: match.range)
                return allowed.contains(token.lowercased()) ? token : "[redacted]"
            }
        return tokens.reduce(into: [String]()) { result, token in
            if token != "[redacted]" || result.last != token {
                result.append(token)
            }
        }.joined(separator: " ")
    }
}

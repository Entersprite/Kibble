import LocalBridgeBackend
import OSLog

extension ProviderDiagnostics {
    /// Counts and statuses only, never an id or text. The directory search's
    /// lines read with:
    ///
    ///     /usr/bin/log show --last 10m --predicate \
    ///         'subsystem == "com.entersprite.kibble" && category == "people"'
    static var native: ProviderDiagnostics {
        let log = Logger(subsystem: "com.entersprite.kibble", category: "MeetingMetadata")
        let people = Logger(subsystem: "com.entersprite.kibble", category: "people")
        return ProviderDiagnostics { event in
            switch event {
            case let .meetingMetadata(visible, ready, queued):
                log.notice("Meeting metadata: visible=\(visible) ready=\(ready) queued=\(queued)")
            case let .meetingDetail(supported):
                log.notice("Meeting detail metadata: supported=\(supported)")
            case .meetingDetailFailed:
                log.notice("Meeting detail metadata: request failed")
            case .meetingCacheWriteFailed:
                log.error("Meeting metadata cache could not be saved")
            case let .peopleSearch(found, unnamed):
                people.notice(
                    "People search: people=\(found, privacy: .public) unnamed=\(unnamed, privacy: .public)"
                )
            case let .peopleSearchFailed(status):
                let code = status.map(String.init) ?? "none"
                people.notice("People search failed: status=\(code, privacy: .public)")
            case let .peopleListFailed(step, failure):
                people.error(
                    """
                    People list failed: step=\(step, privacy: .public) \
                    failure=\(failure, privacy: .public)
                    """
                )
            case let .peopleListRows(total, mapped, withoutUser, outsideGroup):
                people.notice(
                    """
                    People list: rows=\(total, privacy: .public) mapped=\(mapped, privacy: .public) \
                    withoutUser=\(withoutUser, privacy: .public) \
                    outsideGroup=\(outsideGroup, privacy: .public)
                    """
                )
            case let .managementPermissions(rows, matched, legacy, explicit):
                let caps = legacy.map(String.init).joined(separator: ",")
                let flags = explicit.joined(separator: ",")
                people.notice(
                    """
                    Permissions: rows=\(rows, privacy: .public) matched=\(matched, privacy: .public) \
                    legacy=[\(caps, privacy: .public)] explicit=[\(flags, privacy: .public)]
                    """
                )
            case let .peopleRoles(roles):
                let list = roles.map(String.init).joined(separator: ",")
                people.notice("People roles: [\(list, privacy: .public)]")
            }
        }
    }
}

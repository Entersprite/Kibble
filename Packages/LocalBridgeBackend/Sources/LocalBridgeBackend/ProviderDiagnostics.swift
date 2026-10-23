import Foundation

/// Content-free observations; platform logging belongs to the host.
public enum ProviderDiagnostic: Sendable, Hashable {
    case meetingMetadata(visible: Int, ready: Int, queued: Int)
    case meetingDetail(supported: Bool)
    case meetingDetailFailed
    case meetingCacheWriteFailed
    /// A directory search answered: the people kept, and how many of them
    /// came with no name (shown by their email instead).
    case peopleSearch(people: Int, unnamed: Int)
    /// A directory search failed, with the HTTP status when it got one. It
    /// shows nobody a banner, so this is where the failure can be seen.
    case peopleSearchFailed(status: Int?)
    /// A conversation's people list failed at `step` (`listMembers`,
    /// `getMembers` or `permissions`); `failure` names its kind only.
    case peopleListFailed(step: String, failure: String)
    /// A people page answered: its membership rows, how many became
    /// participants, and why the others could not.
    case peopleListRows(total: Int, mapped: Int, withoutUser: Int, outsideGroup: Int)
    /// What a permissions answer held, as enum numbers only: its row count,
    /// whether one row named the asked membership, that row's (or else the
    /// first row's) legacy capabilities, its explicit permission fields as
    /// `number=value`, and the role numbers of a people page's rows.
    case managementPermissions(rows: Int, matched: Bool, legacy: [Int32], explicit: [String])
    case peopleRoles([Int])
}

public struct ProviderDiagnostics: Sendable {
    public let record: @Sendable (ProviderDiagnostic) -> Void

    public init(record: @escaping @Sendable (ProviderDiagnostic) -> Void = { _ in }) {
        self.record = record
    }
}

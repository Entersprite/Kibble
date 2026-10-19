import Foundation

/// Content-free observations; platform logging belongs to the host.
public enum ProviderDiagnostic: Sendable, Hashable {
    case meetingMetadata(visible: Int, ready: Int, queued: Int)
    case meetingDetail(supported: Bool)
    case meetingDetailFailed
    case meetingCacheWriteFailed
}

public struct ProviderDiagnostics: Sendable {
    public let record: @Sendable (ProviderDiagnostic) -> Void

    public init(record: @escaping @Sendable (ProviderDiagnostic) -> Void = { _ in }) {
        self.record = record
    }
}

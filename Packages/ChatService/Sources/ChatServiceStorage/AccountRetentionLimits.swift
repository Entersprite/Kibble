import Foundation

public struct AccountRetentionLimits: Sendable {
    public var journalBytes: Int
    public var maximumAge: TimeInterval
    public var operationCount: Int
    public var operationBytes: Int
    public var legacyOperationCount: Int

    public init(
        journalBytes: Int = 16 * 1024 * 1024, maximumAge: TimeInterval = 7 * 24 * 3600,
        operationCount: Int = 16384, operationBytes: Int = 64 * 1024 * 1024,
        legacyOperationCount: Int = 1024
    ) {
        self.journalBytes = max(1, journalBytes)
        self.maximumAge = maximumAge.isFinite ? max(1, maximumAge) : 7 * 24 * 3600
        self.operationCount = max(1, operationCount)
        self.operationBytes = max(1024, operationBytes)
        self.legacyOperationCount = max(1, legacyOperationCount)
    }
}

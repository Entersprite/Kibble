import Foundation

/// What a backend can actually do.
///
/// **Every flag defaults to `false`, and a missing key decodes to `false`,
/// never `true`.** That direction is the entire point. An older client talking
/// to a newer backend, or a client whose backend simply forgot to answer, must
/// assume *less* capability than exists, never more: a greyed-out button is a
/// mild disappointment, while a button that claims to work and silently drops
/// the user's message is a bug report about lost data. There is no
/// `init(allEnabled:)` for the same reason.
public struct Capabilities: Codable, Hashable, Sendable {
    public var canSendMessages: Bool
    public var canEditMessages: Bool
    public var canDeleteMessages: Bool
    public var canReact: Bool
    public var canSendTypingState: Bool
    public var receivesTypingState: Bool
    public var receivesReadReceipts: Bool
    public var canSetNotificationLevel: Bool
    public var canMarkRead: Bool
    public var supportsThreads: Bool
    public var supportsHistoryCatchUp: Bool

    /// The escape hatch. A newer backend can advertise a capability this build
    /// has no property for, and a newer client can look for it by name without
    /// either side needing a schema bump. Encoded sorted, because a `Set`'s
    /// iteration order is not stable across runs and unstable output would make
    /// every golden-file comparison a coin toss.
    public var extendedFlags: Set<String>

    public init(
        canSendMessages: Bool = false,
        canEditMessages: Bool = false,
        canDeleteMessages: Bool = false,
        canReact: Bool = false,
        canSendTypingState: Bool = false,
        receivesTypingState: Bool = false,
        receivesReadReceipts: Bool = false,
        canSetNotificationLevel: Bool = false,
        canMarkRead: Bool = false,
        supportsThreads: Bool = false,
        supportsHistoryCatchUp: Bool = false,
        extendedFlags: Set<String> = []
    ) {
        self.canSendMessages = canSendMessages
        self.canEditMessages = canEditMessages
        self.canDeleteMessages = canDeleteMessages
        self.canReact = canReact
        self.canSendTypingState = canSendTypingState
        self.receivesTypingState = receivesTypingState
        self.receivesReadReceipts = receivesReadReceipts
        self.canSetNotificationLevel = canSetNotificationLevel
        self.canMarkRead = canMarkRead
        self.supportsThreads = supportsThreads
        self.supportsHistoryCatchUp = supportsHistoryCatchUp
        self.extendedFlags = extendedFlags
    }
}

// MARK: - Coding

public extension Capabilities {
    internal enum CodingKeys: String, CodingKey {
        case canSendMessages
        case canEditMessages
        case canDeleteMessages
        case canReact
        case canSendTypingState
        case receivesTypingState
        case receivesReadReceipts
        case canSetNotificationLevel
        case canMarkRead
        case supportsThreads
        case supportsHistoryCatchUp
        case extendedFlags
    }

    /// Hand-written because synthesis would throw on a missing key, and
    /// throwing is the wrong answer: `{}` is a perfectly meaningful capability
    /// set, meaning "assume nothing works".
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        try self.init(
            canSendMessages: flag(.canSendMessages),
            canEditMessages: flag(.canEditMessages),
            canDeleteMessages: flag(.canDeleteMessages),
            canReact: flag(.canReact),
            canSendTypingState: flag(.canSendTypingState),
            receivesTypingState: flag(.receivesTypingState),
            receivesReadReceipts: flag(.receivesReadReceipts),
            canSetNotificationLevel: flag(.canSetNotificationLevel),
            canMarkRead: flag(.canMarkRead),
            supportsThreads: flag(.supportsThreads),
            supportsHistoryCatchUp: flag(.supportsHistoryCatchUp),
            extendedFlags: Set(
                container.decodeIfPresent([String].self, forKey: .extendedFlags) ?? []
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canSendMessages, forKey: .canSendMessages)
        try container.encode(canEditMessages, forKey: .canEditMessages)
        try container.encode(canDeleteMessages, forKey: .canDeleteMessages)
        try container.encode(canReact, forKey: .canReact)
        try container.encode(canSendTypingState, forKey: .canSendTypingState)
        try container.encode(receivesTypingState, forKey: .receivesTypingState)
        try container.encode(receivesReadReceipts, forKey: .receivesReadReceipts)
        try container.encode(canSetNotificationLevel, forKey: .canSetNotificationLevel)
        try container.encode(canMarkRead, forKey: .canMarkRead)
        try container.encode(supportsThreads, forKey: .supportsThreads)
        try container.encode(supportsHistoryCatchUp, forKey: .supportsHistoryCatchUp)
        try container.encode(extendedFlags.sorted(), forKey: .extendedFlags)
    }
}

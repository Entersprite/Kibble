import Foundation

/// Receive hints for the current call. The IDs belong to its participant
/// registrations, and the order of personal pins is significant.
public struct CallVideoPreferences: Equatable, Sendable {
    public let personalPins: [UUID]
    public let dismissedSharedPins: Set<UUID>
    public let hiddenVideoFeeds: Set<UUID>

    public init(
        personalPins: [UUID] = [], dismissedSharedPins: Set<UUID> = [],
        hiddenVideoFeeds: Set<UUID> = []
    ) {
        self.personalPins = personalPins
        self.dismissedSharedPins = dismissedSharedPins
        self.hiddenVideoFeeds = hiddenVideoFeeds
    }
}

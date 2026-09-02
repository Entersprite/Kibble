import Foundation
import LocalBridgeBackend
@testable import MacHost

/// Records what would have been stored. Touches nothing.
final class FakeCaptureCustody: CaptureCustody, @unchecked Sendable {
    /// How many captures reached storage. The auto-save latch's whole
    /// assertion is that this reaches exactly one.
    private(set) var saveCount = 0

    /// What `save` should answer. `false` models a capture with no Chat
    /// cookie in it.
    var saveSucceeds = true

    /// What `save` should throw instead of answering.
    var saveFailure: (any Error)?

    var storedDescriptionValue: String?

    func save(_: CookieCapture) async throws -> Bool {
        saveCount += 1
        if let saveFailure {
            throw saveFailure
        }
        return saveSucceeds
    }

    func storedDescription() async throws -> String? {
        storedDescriptionValue
    }
}

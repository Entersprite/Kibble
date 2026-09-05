import Foundation

/// One effect together with the failure that was current at the moment it
/// was *enqueued* - not read again later, at the moment it is dequeued and
/// handled.
///
/// This is fix round 1's Finding 1 fix. `ChannelSession.apply(_:)`'s own doc
/// comment has the full trace of why a session-wide "last failure", read at
/// handle time, could pair the wrong failure with the wrong reconnect
/// attempt: two `.failed(_:)` inputs can be applied back-to-back, inside one
/// `openStream()` call, before `run()`'s loop gets a turn to dequeue either
/// one's effect. Carrying the failure inside the queue entry itself removes
/// the stored property that ordering could corrupt.
///
/// Split out of `ChannelSession.swift` rather than left there, the same
/// trade `ChannelAcknowledge.swift` and `NetworkWait.swift` already make on
/// swiftlint's 400-line `file_length` ceiling - this task's own ping
/// addition is what pushed it over. Not `private`: `ChannelSession.swift`
/// still needs to construct and read this from a different file now.
struct QueuedEffect: Sendable {
    let effect: ChannelEffect
    /// Only meaningful for `.reconnect`/`.awaitNetwork` - every other effect
    /// shape ignores it.
    let failure: ChannelFailure?
}

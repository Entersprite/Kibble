import Foundation
@testable import SyncEngine

/// Records every call verbatim, in order - what `AutoMarkReadTraceTests`
/// checks against. `@unchecked Sendable` because every call in these tests
/// arrives from the main actor (through `ChatSessionModel`/
/// `MarkReadTraceRecorder`, both `@MainActor`), never concurrently, the same
/// justification `RecordingBackend`'s own fakes give for the same shape.
final class FakeMarkReadTraceSink: MarkReadTraceSink, @unchecked Sendable {
    private(set) var triggers: [MarkReadTriggerRecord] = []
    private(set) var outcomes: [MarkReadOutcomeRecord] = []
    private(set) var readStates: [MarkReadStateRecord] = []

    func triggerEvaluated(_ record: MarkReadTriggerRecord) {
        triggers.append(record)
    }

    func markOutcome(_ record: MarkReadOutcomeRecord) {
        outcomes.append(record)
    }

    func readStateChanged(_ record: MarkReadStateRecord) {
        readStates.append(record)
    }
}

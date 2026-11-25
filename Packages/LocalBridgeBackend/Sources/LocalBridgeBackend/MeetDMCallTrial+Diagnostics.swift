import Foundation

extension MeetDMCallTrial {
    struct CallDiagnosticStart: Equatable {
        let id: UUID
        let scope: UUID
        let lineIndex: Int
    }

    func beginCallDiagnostics(id: UUID, scope: UUID) {
        callDiagnosticStart = CallDiagnosticStart(id: id, scope: scope, lineIndex: lines.count)
    }

    /// The trial retains a separate account-wide report for debugging. A call
    /// copy starts at the matching attempt and leaves pending native lines intact.
    func diagnosticSnapshot(callID: UUID) async -> [String]? {
        guard !Task.isCancelled else { return nil }
        guard let start = callDiagnosticStart, start.id == callID else { return [] }
        let generation = generation
        let native = native
        let scope = nativeScope
        let recorded = lines.dropFirst(start.lineIndex)
        let pending = scope == start.scope ? await native?.lines ?? [] : []
        guard !Task.isCancelled, self.generation == generation,
              self.native === native, nativeScope == scope, callDiagnosticStart == start else { return nil }
        return Array(recorded) + pending
    }
}

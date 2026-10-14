import Foundation

extension MeetDMCallTrial {
    /// A read-only copy of the existing redacted report. Diagnostics never
    /// consume pending native lines or append data across a replaced trial.
    func diagnosticSnapshot() async -> String? {
        guard !Task.isCancelled else { return nil }
        let generation = generation
        let native = native
        let scope = nativeScope
        let recorded = lines
        let pending = await native?.lines ?? []
        guard !Task.isCancelled, self.generation == generation,
              self.native === native, nativeScope == scope else { return nil }
        return (recorded + pending).joined(separator: "\n")
    }
}

import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    /// Native acknowledgement may arrive ahead of its event reader. Do not
    /// acknowledge device release until the terminal event and lease settle.
    func waitForTerminal(_ id: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            try checkActive()
            if reserved != id {
                if state.currentCallID != id || state.currentPhase?.isTerminal == true {
                    return
                }
            }
            guard ContinuousClock.now < deadline else { throw ServiceFailure.operationUnknown }
            let snapshot = try await read(.init(after: state.version, waitMilliseconds: 20000), control: true)
            if reserved != id, snapshot.currentCallID == id, snapshot.currentPhase?.isTerminal == true {
                return
            }
        }
    }
}

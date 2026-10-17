import DesignSystem
import Foundation
import Observation

@MainActor
protocol CallScreenShareRouting: AnyObject {
    var ended: (() -> Void)? { get set }
    func start() async throws -> Bool
    func suppress()
    func stop() async -> Bool
}

/// One explicit share operation per native call. Cancellation suppresses frames
/// synchronously; settlement and provider cleanup outlive the call window.
@MainActor
@Observable
final class CallScreenShareController {
    private(set) var state: CallScreenShareState?
    private var route: (any CallScreenShareRouting)?
    private var scope = UUID()
    private var operation: Task<Void, Never>?

    func install(_ route: any CallScreenShareRouting) -> UUID {
        clear()
        self.route = route
        state = CallScreenShareState()
        let scope = scope
        route.ended = { [weak self] in
            guard let self, self.scope == scope else { return }
            stop(notice: "Screen sharing ended.")
        }
        return scope
    }

    func clear(ifCurrent expected: UUID? = nil) {
        guard expected == nil || expected == scope else { return }
        scope = UUID()
        let previous = operation
        previous?.cancel(); operation = nil
        if let route {
            route.ended = nil
            route.suppress()
            Task { _ = await previous?.result; _ = await route.stop() }
        }
        route = nil; state = nil
    }

    func toggle() {
        guard let phase = state?.phase else { return }
        if phase != .idle {
            stop(); return
        }
        guard let route, operation == nil else { return }
        let scope = scope
        state = CallScreenShareState(phase: .preparing)
        operation = Task { [weak self] in
            do {
                let started = try await route.start()
                try Task.checkCancellation()
                guard let self, self.scope == scope else { route.suppress(); return }
                state?.phase = started ? .sharing : .idle
                operation = nil
            } catch {
                route.suppress()
                let confirmed = await route.stop()
                guard let self, self.scope == scope, !Task.isCancelled else { return }
                state = CallScreenShareState(notice: confirmed
                    ? "Couldn’t start sharing. Try again and allow screen sharing if macOS asks."
                    : "Sharing stopped on this Mac. The service hasn’t confirmed the presenter left.")
                operation = nil
            }
        }
    }

    private func stop(notice: String? = nil) {
        guard let route, state?.phase != .stopping else { return }
        route.suppress()
        let previous = operation
        previous?.cancel()
        let scope = scope
        state = CallScreenShareState(phase: .stopping, notice: notice)
        operation = Task { [weak self] in
            _ = await previous?.result
            let confirmed = await route.stop()
            guard let self, self.scope == scope, !Task.isCancelled else { return }
            state = CallScreenShareState(notice: confirmed ? notice
                : "Sharing stopped on this Mac. The service hasn’t confirmed the presenter left.")
            operation = nil
        }
    }
}

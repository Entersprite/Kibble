import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend
import Observation

@MainActor
protocol CallScreenShareRouting: AnyObject {
    var ended: (() -> Void)? { get set }
    /// The track being sent while sharing, which the call window previews;
    /// `nil` before capture starts and from the moment it is suppressed.
    var preview: LKRTCVideoTrack? { get }
    /// Whether a share can carry the Mac's sound, so the window offers it.
    var canShareSound: Bool { get }
    func start() async throws -> Bool
    func start(sharingAudio: Bool) async throws -> Bool
    func suppress()
    func stop() async -> Bool
}

extension CallScreenShareRouting {
    var canShareSound: Bool {
        false
    }

    func start(sharingAudio: Bool) async throws -> Bool {
        guard !sharingAudio else { throw CallMediaError.negotiationFailed }
        return try await start()
    }
}

/// One explicit share operation per native call. Cancellation suppresses frames
/// synchronously; settlement and provider cleanup outlive the call window.
@MainActor
@Observable
final class CallScreenShareController {
    private(set) var state: CallScreenShareState?
    /// What is being shared, for the call window's preview; only while sharing.
    private(set) var preview: LKRTCVideoTrack?
    /// The route can share the Mac's sound; only an explicit choice does.
    private(set) var offersSound = false
    private var route: (any CallScreenShareRouting)?
    private var scope = UUID()
    private var operation: Task<Void, Never>?

    func install(_ route: any CallScreenShareRouting) -> UUID {
        clear()
        self.route = route
        offersSound = route.canShareSound
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
        route = nil; state = nil; preview = nil; offersSound = false
    }

    /// Starts sharing, with the Mac's sound only when asked and offered, or
    /// stops or cancels the share already under way.
    func toggle(sharingAudio: Bool = false) {
        guard let phase = state?.phase else { return }
        if phase != .idle {
            stop(); return
        }
        guard let route, operation == nil, !sharingAudio || offersSound else { return }
        let scope = scope
        state = CallScreenShareState(phase: .preparing, sharesSound: sharingAudio)
        operation = Task { [weak self] in
            do {
                let started = try await route.start(sharingAudio: sharingAudio)
                try Task.checkCancellation()
                guard let self, self.scope == scope else { route.suppress(); return }
                state?.phase = started ? .sharing : .idle
                preview = started ? route.preview : nil
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
        preview = nil
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

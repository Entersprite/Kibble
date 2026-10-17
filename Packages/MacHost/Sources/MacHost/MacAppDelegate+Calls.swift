import AppCore
import AppKit
import DesignSystem
import Observation

public extension MacAppDelegate {
    var canSetUpCalls: Bool {
        guard case .running = environment.phase else { return false }
        return callSignIn.isAvailable && environment.calls.canRecover
    }

    func setUpCalls() {
        guard canSetUpCalls else { return }
        Task {
            await environment.calls.recover { await callSignIn.present() }
        }
    }

    /// The call window observes the process-owned controller, independently
    /// of the main chat window's selection and lifetime.
    internal func startCallWindowObservation() {
        let calls = environment.calls
        let callDiagnostics = callDiagnostics
        callWindowHost = AudioCallWindowHost(actions: { id in
            let copy: (() async -> Bool)? = callDiagnostics.isAvailable ? {
                await callDiagnostics.copy(callID: id) { calls.call?.id == id }
            } : nil
            return AudioCallActions(
                accept: {
                    if calls.call?.id == id {
                        calls.accept()
                    }
                },
                decline: {
                    if calls.call?.id == id {
                        calls.decline()
                    }
                },
                toggleMute: {
                    if calls.call?.id == id {
                        calls.toggleMute()
                    }
                },
                hangUp: {
                    if calls.call?.id == id {
                        calls.hangUp()
                    }
                },
                copyDiagnostics: copy
            )
        }, windowClosed: { id in
            if calls.call?.id == id {
                calls.windowClosed()
            }
        })
        observeCallWindow()
    }

    private func observeCallWindow() {
        withObservationTracking {
            callWindowHost?.update(
                call: environment.calls.call,
                windowRequests: environment.calls.windowRequests
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCallWindow() }
        }
    }

    /// Quit waits for the same media/watch teardown as sign-out. Merely
    /// closing the chat window keeps the session and incoming listener alive.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        memoryPressureSource?.cancel()
        environment.releasePresentationCaches()
        Task { @MainActor [environment] in
            await self.callSignIn.invalidate()
            await environment.calls.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

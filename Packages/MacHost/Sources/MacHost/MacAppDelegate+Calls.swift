import AppCore
import AppKit
import DesignSystem
import Observation

extension MacAppDelegate {
    /// The call window observes the process-owned controller, independently
    /// of the main chat window's selection and lifetime.
    func startCallWindowObservation() {
        let calls = environment.calls
        callWindowHost = AudioCallWindowHost(actions: { id in
            AudioCallActions(
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
                }
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
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task { @MainActor [environment] in
            await environment.calls.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

import AppCore
import AppKit
import ChatKit
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
        let environment = environment
        let calls = environment.calls
        let callDiagnostics = callDiagnostics
        let audioDevices = callAudioDevices
        let video = callVideo
        callWindowHost = AudioCallWindowHost(actions: { id in
            var actions = Self.callActions(
                for: id,
                calls: calls,
                audioDevices: audioDevices,
                video: video,
                diagnostics: callDiagnostics
            )
            actions.callBack = Self.callBack(after: id, environment: environment)
            return actions
        }, windowClosed: { id in
            if calls.call?.id == id {
                calls.windowClosed()
            }
        })
        callAlerts = IncomingCallAlerts(
            post: { [notifications] in await notifications.postCall($0) },
            withdraw: { [notifications] in notifications.withdrawCall($0) }
        )
        startCallResponseObservation()
        observeCallWindow()
    }

    private static func callActions(
        for id: UUID, calls: AudioCallController, audioDevices: CallAudioDeviceController,
        video: CallVideoController, diagnostics: AudioCallDiagnosticExporter
    ) -> AudioCallActions {
        let copy: (() async -> Bool)? = diagnostics.isAvailable ? {
            await diagnostics.copy(callID: id) { calls.call?.id == id }
        } : nil
        var actions = AudioCallActions(
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
            copyDiagnostics: copy,
            selectMicrophone: { device in
                if calls.call?.id == id {
                    audioDevices.select(device, microphone: true)
                }
            },
            selectSpeaker: { device in
                if calls.call?.id == id {
                    audioDevices.select(device, microphone: false)
                }
            }
        )
        addVideoActions(to: &actions, for: id, calls: calls, video: video)
        return actions
    }

    private static func addVideoActions(
        to actions: inout AudioCallActions, for id: UUID, calls: AudioCallController,
        video: CallVideoController
    ) {
        actions.toggleCamera = {
            if calls.call?.id == id, calls.call?.phase == .connected || calls.call?.phase == .ringing,
               !calls.isEnding {
                video.toggle()
            }
        }
        actions.selectCamera = { device in
            if calls.call?.id == id, calls.call?.phase == .connected || calls.call?.phase == .ringing,
               !calls.isEnding {
                video.select(device)
            }
        }
        actions.toggleScreenSharing = {
            if calls.call?.id == id, calls.call?.phase == .connected || calls.call?.phase == .ringing,
               !calls.isEnding {
                video.screenSharing.toggle()
            }
        }
    }

    private func startCallResponseObservation() {
        callResponseTask = Task { [weak self, notifications] in
            for await response in notifications.callResponses {
                guard !Task.isCancelled, let self, !environment.calls.isEnding,
                      IncomingCallAlerts.isCurrent(response, call: self.environment.calls.call)
                else { continue }
                switch response {
                case .show: callWindowHost?.show()
                case .answer: callWindowHost?.show(); environment.calls.accept()
                case .decline: environment.calls.decline()
                }
            }
        }
    }

    private func observeCallWindow() {
        // Read outside the tracking scope: the directory changes with every
        // presence update, which alone is no reason to rebuild the call window.
        let person = callPerson()
        withObservationTracking {
            let alertsIncoming = updateCallAlert()
            callWindowHost?.update(
                call: environment.calls.call,
                windowRequests: environment.calls.windowRequests,
                devices: callAudioDevices.devices, alertsIncoming: alertsIncoming, video: callVideo,
                person: person
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCallWindow() }
        }
    }

    /// The other person's directory entry, for the call window's photo.
    private func callPerson() -> Member? {
        guard let call = environment.calls.call, case let .running(model) = environment.phase
        else { return nil }
        return model.directory[call.recipient.memberID]
    }

    /// Calls the same person again from a finished call's window, offered only
    /// while that conversation can still be called. Read only for a finished
    /// call, so a live call's window does not follow the conversation list.
    private static func callBack(after id: UUID, environment: AppEnvironment) -> (() -> Void)? {
        let calls = environment.calls
        guard let call = calls.call, call.id == id, call.phase.isTerminal,
              case let .running(model) = environment.phase,
              let conversation = model.conversations.first(where: { $0.id == call.recipient.conversationID }),
              calls.canCall(conversation: conversation, directory: model.directory, me: model.me)
        else { return nil }
        return {
            guard calls.call?.id == id, calls.call?.phase.isTerminal == true,
                  case let .running(model) = environment.phase,
                  let conversation = model.conversations.first(where: { $0.id == conversation.id })
            else { return }
            calls.startCall(in: conversation, members: Array(model.directory.values), me: model.me)
        }
    }

    private func updateCallAlert() -> Bool {
        var rule: ResolvedRule?
        if case let .running(model) = environment.phase,
           environment.settings.account != nil,
           let id = environment.calls.call?.recipient.conversationID,
           let conversation = model.conversations.first(where: { $0.id == id }) {
            rule = environment.settings.resolved(for: conversation)
        }
        let paused = environment.settings.isPaused || environment.calls.isEnding
        callAlerts?.update(call: environment.calls.call, rule: rule, paused: paused)
        return !paused && (rule?.delivery == .banner || rule?.delivery == .bannerAndSound)
    }

    /// Quit waits for the same media/watch teardown as sign-out. Merely
    /// closing the chat window keeps the session and incoming listener alive.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        callAlerts?.update(call: nil, rule: nil, paused: true)
        callResponseTask?.cancel()
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

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

    /// Starts a DM call with the camera on, for the conversation header's
    /// Video Call button. `nil`, which draws no button, while this session's
    /// calls cannot carry video.
    var videoCall: ((Conversation.ID) -> Void)? {
        guard callVideo.isAvailable, environment.calls.isAvailable else { return nil }
        return { [weak self] id in self?.startVideoCall(in: id) }
    }

    /// The same start as the header's Call button. Only a call this starts
    /// gets the camera: a click while another call is going on raises that
    /// call's window and leaves its camera alone.
    private func startVideoCall(in id: Conversation.ID) {
        let calls = environment.calls
        guard case let .running(model) = environment.phase,
              let conversation = model.conversations.first(where: { $0.id == id })
        else { return }
        let members = Array(model.directory.values)
        guard let call = calls.startCall(in: conversation, members: members, me: model.me) else { return }
        callCamera.request(for: call, calls: calls, video: callVideo)
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
        }, closesFinishedCalls: { [callSettings] in callSettings.closesFinishedCalls })
        callAlerts = IncomingCallAlerts(
            post: { [notifications] in await notifications.postCall($0) },
            withdraw: { [notifications] in notifications.withdrawCall($0) },
            showPanel: { [weak self] in self?.showCallPanel($0) },
            hidePanel: { [callPanel] in callPanel.hide() },
            ring: { [callRinger] in $0 ? callRinger.start() : callRinger.stop() }
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

    /// The panel's buttons act on the call they were shown for, and only while
    /// it is still ringing, like a notification's actions.
    private func showCallPanel(_ content: IncomingCallPanelContent) {
        let id = content.callID
        callPanel.show(content, actions: IncomingCallPanelHost.Actions(
            accept: { [weak self] in self?.respondFromPanel(.answer(id)) },
            decline: { [weak self] in self?.respondFromPanel(.decline(id)) },
            open: { [weak self] in self?.respondFromPanel(.show(id)) },
            dismiss: { [weak self] in self?.callAlerts?.dismiss() }
        ))
    }

    private func respondFromPanel(_ response: IncomingCallResponse) {
        let calls = environment.calls
        guard !calls.isEnding, IncomingCallAlerts.isCurrent(response, call: calls.call) else { return }
        switch response {
        case .show:
            callWindowHost?.show()
            NSApp.activate()
        case .answer:
            callWindowHost?.show()
            NSApp.activate()
            calls.accept()
        case .decline:
            calls.decline()
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
            let alertsIncoming = updateCallAlert(person: person)
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

    /// Returns whether the call window should rise for a new incoming call.
    private func updateCallAlert(person: Member?) -> Bool {
        var rule: ResolvedRule?
        if case let .running(model) = environment.phase,
           environment.settings.account != nil,
           let id = environment.calls.call?.recipient.conversationID,
           let conversation = model.conversations.first(where: { $0.id == id }) {
            rule = environment.settings.resolved(for: conversation)
        }
        let paused = environment.settings.isPaused || environment.calls.isEnding
        let call = environment.calls.call
        var surface = IncomingCallSurface.notificationsOnly
        // Focus and mirroring are read only while a call rings.
        if call?.direction == .incoming, call?.phase == .incoming {
            surface = IncomingCallSurface(
                showsPanel: callSettings.showsPanel, rings: callSettings.rings,
                focused: callSettings.isFocused, mirrored: DisplayMirroring.isActive(), person: person
            )
        }
        return callAlerts?.update(call: call, rule: rule, paused: paused, surface: surface) ?? false
    }

    /// Quit waits for the same media/watch teardown as sign-out. Merely
    /// closing the chat window keeps the session and incoming listener alive.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        callAlerts?.update(call: nil, rule: nil, paused: true)
        callResponseTask?.cancel()
        callCamera.cancel()
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

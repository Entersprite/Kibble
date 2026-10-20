import AppCore
import AppKit
import ChatAPI
import ChatKit
import DesignSystem
import Observation

/// Account selection never rebinds a call window or its native hardware controls.
@MainActor
final class NativeAccountCallPresentation {
    let environment: AppEnvironment
    let binding: NativeAccountCallBinding
    private let settings: CallSettingsModel
    let notificationScope = UUID()
    /// Which account this is while several are connected, asked when shown.
    private let accountLabel: @MainActor () -> String?
    private let panel = IncomingCallPanelHost()
    private let ringer: CallRinger
    private var window: AudioCallWindowHost?
    private var alerts: IncomingCallAlerts?
    private var stopped = false

    init(
        environment: AppEnvironment, binding: NativeAccountCallBinding,
        settings: CallSettingsModel, notifications: UserNotificationDelivery,
        accountLabel: @escaping @MainActor () -> String? = { nil }
    ) {
        self.environment = environment; self.binding = binding; self.settings = settings
        self.accountLabel = accountLabel
        ringer = CallRinger { settings.ringtoneURL }
        let calls = environment.calls
        window = AudioCallWindowHost(actions: { id in
            var actions = MacAppDelegate.callActions(
                for: id, calls: calls, audioDevices: binding.audioDevices,
                video: binding.video, diagnostics: binding.diagnostics
            )
            actions.callBack = MacAppDelegate.callBack(after: id, environment: environment)
            actions.imageLoader = environment.imageLoader
            actions.accountLabel = accountLabel()
            return actions
        }, windowClosed: { id in
            if calls.call?.id == id {
                calls.windowClosed()
            }
        }, closesFinishedCalls: { settings.closesFinishedCalls })
        alerts = IncomingCallAlerts(
            post: { [notificationScope] alert in
                var scoped = alert; scoped.scope = notificationScope
                await notifications.postCall(scoped)
            }, withdraw: { [notificationScope] in notifications.withdrawCall($0, scope: notificationScope) },
            showPanel: { [weak self] in self?.showPanel($0) }, hidePanel: { [panel] in panel.hide() },
            ring: { [ringer] in $0 ? ringer.start() : ringer.stop() }
        )
        observe()
    }

    func respondToNotification(_ response: IncomingCallResponse) {
        guard response.scope == notificationScope else { return }
        respond(response)
    }

    private func respond(_ response: IncomingCallResponse) {
        let calls = environment.calls
        guard !stopped, !calls.isEnding,
              IncomingCallAlerts.isCurrent(response, call: calls.call) else { return }
        switch response {
        case .show: window?.show(); NSApp.activate()
        case .answer: window?.show(); NSApp.activate(); calls.accept()
        case .decline: calls.decline()
        }
    }

    func stop() {
        stopped = true
        alerts?.update(call: nil, rule: nil, paused: true)
        window?.update(call: nil, windowRequests: 0)
    }

    private func showPanel(_ content: IncomingCallPanelContent) {
        let id = content.callID
        var content = content
        content.accountLabel = accountLabel()
        panel.show(content, actions: .init(
            accept: { [weak self] in self?.respond(.answer(id)) },
            decline: { [weak self] in self?.respond(.decline(id)) },
            open: { [weak self] in self?.respond(.show(id)) },
            dismiss: { [weak self] in self?.alerts?.dismiss() },
            imageLoader: environment.imageLoader
        ))
    }

    private func observe() {
        guard !stopped else { return }
        var person: Member?
        if let call = environment.calls.call, case let .running(model) = environment.phase {
            person = model.directory[call.recipient.memberID]
        }
        withObservationTracking {
            let call = environment.calls.call
            var rule: ResolvedRule?
            if case let .running(model) = environment.phase, environment.settings.account != nil,
               let conversation = model.conversations
               .first(where: { $0.id == call?.recipient.conversationID }) {
                rule = environment.settings.resolved(for: conversation)
            }
            var surface = IncomingCallSurface.notificationsOnly
            if call?.direction == .incoming, call?.phase == .incoming {
                surface = IncomingCallSurface(
                    showsPanel: settings.showsPanel, rings: settings.rings,
                    focused: settings.isFocused, mirrored: DisplayMirroring.isActive(), person: person
                )
            }
            let raises = alerts?.update(
                call: call, rule: rule, paused: environment.settings.isPaused || environment.calls.isEnding,
                surface: surface
            ) ?? false
            window?.update(
                call: call, windowRequests: environment.calls.windowRequests,
                devices: binding.audioDevices.devices, alertsIncoming: raises, video: binding.video,
                person: person
            )
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observe() } }
    }
}

@MainActor
final class NativeAccountCallCoordinator {
    private let host: SystemAccountHost
    private let settings: CallSettingsModel
    private let notifications: UserNotificationDelivery
    private var presentations: [ConnectedAccountID: NativeAccountCallPresentation] = [:]
    private var responses: Task<Void, Never>?
    private var stopped = false

    init(
        host: SystemAccountHost,
        settings: CallSettingsModel,
        notifications: UserNotificationDelivery
    ) {
        self.host = host; self.settings = settings; self.notifications = notifications
        responses = Task { [weak self] in
            for await response in notifications.callResponses {
                guard !Task.isCancelled, let self else { return }
                for presentation in presentations.values {
                    presentation.respondToNotification(response)
                }
            }
        }
        observe()
    }

    func stop() async {
        stopped = true
        responses?.cancel(); await responses?.value; responses = nil
        presentations.values.forEach { $0.stop() }
        presentations = [:]
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            let workspace = host.workspace
            let current = Set(workspace?.accounts.compactMap { account -> ConnectedAccountID? in
                guard let environment = workspace?.environment(for: account.id),
                      let binding = host.callBindings.binding(for: account) else { return nil }
                if presentations[account.id]?.environment !== environment {
                    presentations.removeValue(forKey: account.id)?.stop()
                    let id = account.id
                    presentations[account.id] = NativeAccountCallPresentation(
                        environment: environment, binding: binding, settings: settings,
                        notifications: notifications
                    ) { [weak host] in
                        guard let workspace = host?.workspace,
                              workspace.accounts.count > 1 else { return nil }
                        return workspace.accountLabels[id]
                    }
                }
                return account.id
            } ?? [])
            for id in Array(presentations.keys) where !current.contains(id) {
                presentations.removeValue(forKey: id)?.stop()
            }
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observe() } }
    }
}

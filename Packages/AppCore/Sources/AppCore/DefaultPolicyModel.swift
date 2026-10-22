import ChatAPI
import ChatKit
import DesignSystem
import Foundation
import Observation
import ServiceClient

/// One process-owned editor for shared overall defaults. Writes are serialized;
/// changing another field while a request is pending keeps both choices.
@MainActor
@Observable
public final class DefaultPolicyModel {
    public private(set) var rule = NotificationRule()
    public private(set) var isAvailable = false
    public private(set) var lastError: String?
    private let client: AccountClient
    private var acknowledged: AccountPolicy?
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var sequence = 0
    private var loadID = UUID()

    public init(client: AccountClient) {
        self.client = client
    }

    public func load() async {
        guard worker == nil else { return }
        await reload()
    }

    private func reload() async {
        let loadID = UUID()
        self.loadID = loadID
        let sequence = sequence
        do {
            let policy = try await client.call(GetDefaultPolicy())
            guard !stopped, self.loadID == loadID, sequence == self.sequence else { return }
            acknowledged = policy
            rule = policy.settings.rule(for: .global) ?? .init()
            isAvailable = true
            lastError = nil
        } catch {
            guard !stopped, self.loadID == loadID, sequence == self.sequence else { return }
            lastError = "Kibble couldn’t load global defaults. Try reopening Settings."
        }
    }

    public func update(_ rule: NotificationRule) {
        guard isAvailable, !stopped else { return }
        self.rule = rule
        sequence += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.savePending() }
    }

    private func savePending() async {
        defer { worker = nil }
        while !stopped, let base = acknowledged {
            let submitted = rule
            let sequence = sequence
            do {
                let policy = try await client.call(SetDefaultPolicy(
                    rule: submitted, expectedRevision: base.revision
                ))
                guard !stopped else { return }
                acknowledged = policy
                lastError = nil
                if sequence == self.sequence {
                    return
                }
            } catch {
                guard !stopped else { return }
                // A rejected CAS cannot overwrite another editor's privacy choice.
                // Refresh before accepting another explicit edit.
                isAvailable = false
                await reload()
                guard !stopped else { return }
                lastError = "Kibble couldn’t save global defaults. Your saved settings are shown."
                return
            }
        }
    }

    public func stop() async {
        stopped = true
        worker?.cancel()
        await worker?.value
        worker = nil
        isAvailable = false
    }
}

public extension DefaultPolicyModel {
    func settingsState(devicePause: DeviceNotificationPause?) -> NotificationSettingsState {
        var state = NotificationSettingsState(
            isAvailable: isAvailable, globalRule: rule, global: NotificationRule.resolve([rule]),
            lastError: lastError ?? devicePause?.lastError, pauseStatus: devicePause?.status
        )
        state.editsSharedDefaults = true
        return state
    }

    func settingsActions(
        openSystemSettings: @escaping () -> Void, devicePause: DeviceNotificationPause?
    ) -> NotificationSettingsActions {
        NotificationSettingsActions(
            reset: { [weak self, weak devicePause] in
                self?.update(.init())
                devicePause?.resume()
            },
            updateGlobal: { [weak self] in self?.update($0) },
            openSystemSettings: openSystemSettings,
            pause: { [weak devicePause] in devicePause?.pause(for: $0) },
            resume: { [weak devicePause] in devicePause?.resume() }
        )
    }
}

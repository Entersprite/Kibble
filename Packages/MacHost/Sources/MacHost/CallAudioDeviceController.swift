import DesignSystem
import Foundation
import Observation

/// One local route for the active media engine. A microphone or speaker the
/// person picks is saved in `preferences`, and the next route starts on it when
/// that device is connected; otherwise it starts on System Default.
@MainActor
@Observable
public final class CallAudioDeviceController {
    public private(set) var devices: CallAudioDevices?
    @ObservationIgnored private let preferences: CallDevicePreferences?
    private var scope = UUID()
    private var refreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var route: (any CallAudioRouting)?
    private var selectionRevision = 0
    private var selectionFailure: String?

    public convenience init() {
        self.init(preferences: nil)
    }

    init(preferences: CallDevicePreferences?) {
        self.preferences = preferences
    }

    @discardableResult
    func install(_ route: any CallAudioRouting) -> UUID {
        clear()
        self.route = route
        let scope = scope
        let saved = preferences.map { [($0.microphone, true), ($0.speaker, false)] } ?? []
        refreshTask = Task { [weak self] in
            // Before the first snapshot, so the picker never shows a default
            // that is about to change. A saved device that is missing, or that
            // refuses the switch, leaves System Default with no notice.
            for (persistentID, microphone) in saved where !persistentID.isEmpty {
                _ = await route.restore(persistentID, microphone: microphone)
            }
            while !Task.isCancelled {
                let revision = self?.selectionRevision
                let snapshot = await route.snapshot()
                guard !Task.isCancelled, let self, self.scope == scope else { return }
                if selectionTask == nil, revision == selectionRevision {
                    var snapshot = snapshot
                    snapshot.notice = snapshot.notice ?? selectionFailure
                    devices = snapshot
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        return scope
    }

    func clear(ifCurrent expected: UUID? = nil) {
        if let expected, expected != scope {
            return
        }
        scope = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        route = nil
        devices = nil
        selectionFailure = nil
    }

    public func select(_ id: String, microphone: Bool) {
        guard let route, selectionTask == nil, devices != nil else { return }
        let scope = scope
        selectionRevision += 1
        selectionFailure = nil
        devices?.isUpdating = true
        selectionTask = Task { [weak self] in
            let succeeded = await route.select(id, microphone: microphone)
            // A device the hardware cannot name lastingly is not kept; the
            // next call then starts on System Default, never on a stale choice.
            let persistentID = succeeded && !id.isEmpty
                ? await route.persistentID(of: id, microphone: microphone) ?? "" : ""
            var snapshot = await route.snapshot()
            guard !Task.isCancelled, let self, self.scope == scope else { return }
            if succeeded {
                preferences?.saveAudio(persistentID, microphone: microphone)
            } else {
                selectionFailure = "Couldn’t switch audio devices. Please choose another device."
                snapshot.notice = selectionFailure
            }
            devices = snapshot
            selectionTask = nil
        }
    }
}

protocol CallAudioRouting: Sendable {
    func snapshot() async -> CallAudioDevices
    func select(_ id: String, microphone: Bool) async -> Bool
    /// What to save for a connected device: an identifier that survives
    /// relaunch and reconnection, unlike the picker's. `nil` when unknown.
    func persistentID(of id: String, microphone: Bool) async -> String?
    /// Selects the connected device saved as `persistentID`; `false`, with
    /// nothing changed, when none is connected.
    func restore(_ persistentID: String, microphone: Bool) async -> Bool
}

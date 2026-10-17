import DesignSystem
import Foundation
import Observation

/// One local route for the active media engine. No device preference survives
/// closing that engine or replacing the signed-in session.
@MainActor
@Observable
public final class CallAudioDeviceController {
    public private(set) var devices: CallAudioDevices?
    private var scope = UUID()
    private var refreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var route: (any CallAudioRouting)?
    private var selectionRevision = 0
    private var selectionFailure: String?

    public init() {}

    @discardableResult
    func install(_ route: any CallAudioRouting) -> UUID {
        clear()
        self.route = route
        let scope = scope
        refreshTask = Task { [weak self] in
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
            var snapshot = await route.snapshot()
            guard !Task.isCancelled, let self, self.scope == scope else { return }
            if !succeeded {
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
}

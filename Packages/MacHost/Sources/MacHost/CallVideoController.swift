import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC
import Observation

/// Session-local camera operations. Every completion is checked against the
/// engine that installed it; replacement never enables a previous camera.
/// The camera the person picks is saved in `preferences` and selected again by
/// the next engine while it is connected; it is never turned on by itself.
@MainActor
@Observable
public final class CallVideoController {
    /// Whether this session's calls can carry video: true for the native media
    /// engine, which brings a camera. The fixture's calls have none.
    public internal(set) var isAvailable = false
    public private(set) var camera: CallCameraState?
    var localTrack: LKRTCVideoTrack?
    var remoteTrack: LKRTCVideoTrack?
    var remoteVisible = false
    var remotePresentation = false
    let screenSharing = CallScreenShareController()
    private var route: (any CallCameraRouting)?
    private var scope = UUID()
    private var operation: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    @ObservationIgnored private let preferences: CallDevicePreferences?

    public convenience init() {
        self.init(preferences: nil)
    }

    init(preferences: CallDevicePreferences?) {
        self.preferences = preferences
    }

    func install(_ route: any CallCameraRouting, local: LKRTCVideoTrack? = nil) -> UUID {
        clear()
        self.route = route
        localTrack = local
        let devices = route.devices()
        let saved = preferences?.camera ?? ""
        camera = CallCameraState(
            devices: devices, selected: devices.contains { $0.id == saved } ? saved : ""
        )
        let scope = scope
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.scope == scope else { return }
                let devices = route.devices()
                camera?.devices = devices
                if let selected = camera?.selected, !selected.isEmpty,
                   !devices.contains(where: { $0.id == selected }) {
                    camera?.selected = ""
                }
                if let camera, camera.isOn, !devices.contains(where: { $0.id == route.activeDevice }) {
                    turnOff(notice: "Camera disconnected. Choose a camera to turn video on again.")
                }
            }
        }
        return scope
    }

    func unavailable(_ route: any CallCameraRouting, local: LKRTCVideoTrack) -> UUID {
        let scope = install(route, local: local)
        camera?.isUpdating = true
        camera?.notice = "Video is unavailable for this call. Voice remains connected."
        return scope
    }

    func clear(ifCurrent expected: UUID? = nil) {
        guard expected == nil || expected == scope else { return }
        scope = UUID()
        operation?.cancel(); operation = nil
        refresh?.cancel(); refresh = nil
        route?.suppress()
        route = nil
        localTrack = nil; remoteTrack = nil; remoteVisible = false; remotePresentation = false; camera = nil
    }

    func showRemote(_ track: LKRTCVideoTrack?, visible: Bool, ifCurrent expected: UUID) {
        guard expected == scope else { return }
        remoteTrack = track
        remoteVisible = visible
    }

    func showPresentation(_ visible: Bool, ifCurrent expected: UUID) {
        guard expected == scope else { return }
        remotePresentation = visible
    }

    public func toggle() {
        guard let camera else { return }
        if camera.isOn {
            turnOff()
        } else {
            turnOn(camera.selected)
        }
    }

    /// Turns the chosen camera on; does nothing while it is on or changing.
    public func turnOn() {
        guard let camera, !camera.isOn, !camera.isUpdating else { return }
        turnOn(camera.selected)
    }

    public func select(_ id: String) {
        guard let camera, !camera.isUpdating,
              id.isEmpty || camera.devices.contains(where: { $0.id == id }) else { return }
        self.camera?.selected = id
        preferences?.saveCamera(id)
        if camera.isOn {
            turnOn(id)
        }
    }

    private func turnOn(_ id: String) {
        guard let route, operation == nil else { return }
        let scope = scope
        camera?.isUpdating = true; camera?.notice = nil
        operation = Task { [weak self] in
            do {
                try await route.start(id)
                try Task.checkCancellation()
                guard let self, self.scope == scope else { route.suppress(); return }
                try await route.announce(true)
                try Task.checkCancellation()
                guard self.scope == scope else { route.suppress(); return }
                route.send(true)
                camera?.isOn = true
                camera?.isUpdating = false
                operation = nil
            } catch {
                route.suppress()
                await route.stop()
                guard let self, self.scope == scope else { return }
                camera?.isOn = false; camera?.isUpdating = false
                camera?.notice = error as? CameraFailure == .denied
                    ? "Camera access is off. Allow Kibble in System Settings › Privacy & Security › Camera."
                    : "Couldn’t turn on the camera. Choose a camera and try again."
                operation = nil
            }
        }
    }

    private func turnOff(notice: String? = nil) {
        guard let route else { return }
        route.suppress()
        let previous = operation
        previous?.cancel()
        let scope = scope
        camera?.isOn = false; camera?.isUpdating = true; camera?.notice = notice
        operation = Task { [weak self] in
            _ = await previous?.result
            await route.stop()
            try? await route.announce(false)
            guard !Task.isCancelled, let self, self.scope == scope else { return }
            camera?.isUpdating = false
            operation = nil
        }
    }
}

enum CameraFailure: Error { case denied, unavailable, closed }

@MainActor
protocol CallCameraRouting: AnyObject {
    var activeDevice: String { get }
    func devices() -> [CallCameraDevice]
    func start(_ id: String) async throws
    func stop() async
    func suppress()
    func send(_ enabled: Bool)
    func announce(_ enabled: Bool) async throws
}

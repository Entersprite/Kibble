import Foundation
import Observation
import SwiftUI

@MainActor
protocol CallPreparationCameraRoute: AnyObject {
    var view: AnyView { get }
    func authorize() async -> Bool
    func start(device id: String) async -> Bool
    func observeLoss(_ callback: @escaping @MainActor @Sendable () -> Void)
    func stop() -> Task<Void, Never>
}

@MainActor
@Observable
final class CallPreparationCamera {
    private(set) var view: AnyView?
    private(set) var isStarting = false
    private(set) var isJoining = false
    private(set) var notice: String?
    @ObservationIgnored private var meeting: UUID?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var attempt: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var route: (any CallPreparationCameraRoute)?
    @ObservationIgnored private var usesCamera = false
    @ObservationIgnored private var device: String?
    @ObservationIgnored private let makeRoute: () -> any CallPreparationCameraRoute

    init(makeRoute: @escaping () -> any CallPreparationCameraRoute = { NativePreparationCameraRoute() }) {
        self.makeRoute = makeRoute
    }

    func bind(_ meeting: UUID?) {
        guard self.meeting != meeting else { return }
        hide()
        self.meeting = meeting
        isJoining = false
        notice = nil
    }

    func configure(device: String?, resumePreview: (@MainActor () -> Bool)? = nil) {
        guard self.device != device else { return }
        self.device = device
        guard isStarting || view != nil else { return }
        hide()
        if let resumePreview, let meeting {
            toggle(in: meeting, mayCapture: resumePreview)
        } else {
            notice = "Camera changed. Start the preview again."
        }
    }

    func toggle(in id: UUID, mayCapture: @escaping @MainActor () -> Bool) {
        guard meeting == id, !isJoining, let device else { return }
        if isStarting || view != nil {
            hide()
            return
        }
        guard mayCapture() else { return }
        notice = nil
        isStarting = true
        let revision = revision
        let route = makeRoute()
        self.route = route
        attempt = Task { [weak self] in
            guard self?.revision == revision else { return }
            let authorized = await route.authorize()
            await self?.activate(
                route, device: device, revision: revision, authorized: authorized, mayCapture: mayCapture
            )
        }
    }

    private func activate(
        _ route: any CallPreparationCameraRoute, device: String, revision: Int,
        authorized: Bool, mayCapture: @MainActor () -> Bool
    ) async {
        guard self.revision == revision else { return }
        guard authorized else {
            fail("Camera access is off. Allow Kibble in System Settings › Privacy & Security › Camera.")
            return
        }
        await cleanup?.value
        guard self.revision == revision else { return }
        guard mayCapture() else { hide(); return }
        usesCamera = true
        let started = await route.start(device: device)
        guard self.revision == revision else { return }
        guard started else { fail("Couldn’t start the camera preview."); return }
        guard mayCapture() else { hide(); return }
        view = route.view
        isStarting = false
        attempt = nil
        route.observeLoss { [weak self] in
            guard let self, self.revision == revision else { return }
            fail("Camera preview stopped.")
        }
    }

    func hide() {
        revision += 1
        usesCamera = false
        attempt?.cancel()
        attempt = nil
        if let route {
            let previous = cleanup
            let stopped = route.stop()
            cleanup = Task {
                await previous?.value
                await stopped.value
            }
        }
        route = nil
        if view != nil {
            view = nil
        }
        if isStarting {
            isStarting = false
        }
    }

    func suspendCapture() {
        if usesCamera {
            hide()
        }
    }

    func join(_ id: UUID, after audioCleanup: Task<Void, Never>? = nil, perform: @escaping () -> Void) {
        guard meeting == id, !isJoining else { return }
        hide()
        let cleanup = cleanup
        guard cleanup != nil || audioCleanup != nil else { perform(); return }
        isJoining = true
        Task { [weak self] in
            await cleanup?.value
            await audioCleanup?.value
            guard let self, meeting == id, isJoining else { return }
            isJoining = false
            perform()
        }
    }

    private func fail(_ message: String) {
        hide()
        notice = message
    }

    isolated deinit {
        attempt?.cancel()
        _ = route?.stop()
    }
}

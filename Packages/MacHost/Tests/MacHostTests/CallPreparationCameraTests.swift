import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import MacHost

@MainActor
struct CallPreparationCameraTests {
    @Test func nativeSurfaceDisplaysAnIdleCaptureSessionWithoutMediaOutputs() throws {
        let route = NativePreparationCameraRoute()
        let host = NSHostingView(rootView: route.view.frame(width: 256, height: 144))
        host.frame.size = NSSize(width: 256, height: 144)
        host.layoutSubtreeIfNeeded()
        let preview = try #require(nativePreview(in: host))
        let capture = try #require(preview.session)
        #expect(!capture.isRunning && capture.inputs.isEmpty && capture.outputs.isEmpty)
        #expect(preview.bounds.size == NSSize(width: 256, height: 144))
    }

    @Test func aReplacedPreparationCannotStartAfterPermissionReturns() async {
        let route = PreviewRoute()
        route.holdsPermission = true
        let camera = CallPreparationCamera { route }
        let first = UUID()
        camera.bind(first)
        camera.configure(device: "camera")
        camera.toggle(in: first) { true }
        #expect(await eventually { route.permission != nil })
        camera.bind(UUID())
        route.permission?.resume(returning: true)
        route.permission = nil
        await Task.yield()
        #expect(route.starts == 0 && route.stops == 1)
        #expect(camera.view == nil && !camera.isStarting)
    }

    @Test(arguments: [false, true])
    func joinWaitsForCaptureReleaseAndRunsOnlyOnceUnlessCanceled(_ canceled: Bool) async {
        let route = PreviewRoute()
        route.holdsStop = true
        let camera = CallPreparationCamera { route }
        let id = UUID()
        camera.bind(id)
        camera.configure(device: "camera")
        camera.toggle(in: id) { true }
        #expect(await eventually { camera.view != nil })
        var joins = 0
        camera.join(id) { joins += 1 }
        camera.join(id) { joins += 1 }
        #expect(camera.isJoining && camera.view == nil && joins == 0)
        if canceled {
            camera.bind(nil)
        }
        route.finishStop()
        #expect(await eventually { joins == (canceled ? 0 : 1) && !camera.isJoining })
    }

    @Test func aLostPreviewWithdrawsTheImageAndReportsTheFailure() async {
        let route = PreviewRoute()
        let camera = CallPreparationCamera { route }
        let id = UUID()
        camera.bind(id)
        camera.configure(device: "camera")
        camera.toggle(in: id) { true }
        #expect(await eventually { camera.view != nil })
        route.loss?()
        #expect(camera.view == nil && camera.notice == "Camera preview stopped." && route.stops == 1)
    }

    @Test func livePreviewSwitchWaitsForTheOldDeviceAndIgnoresItsLossCallback() async {
        let first = PreviewRoute(), second = PreviewRoute()
        first.holdsStop = true
        var routes = [first, second]
        let camera = CallPreparationCamera { routes.removeFirst() }
        let id = UUID()
        camera.bind(id)
        camera.configure(device: "front")
        #expect(first.devices.isEmpty)
        camera.toggle(in: id) { true }
        #expect(await eventually { camera.view != nil && first.devices == ["front"] })
        camera.configure(device: "external", resumePreview: { true })
        #expect(camera.view == nil && camera.isStarting && first.stops == 1 && second.devices.isEmpty)
        first.finishStop()
        #expect(await eventually { camera.view != nil && second.devices == ["external"] })
        first.loss?()
        #expect(camera.view != nil && second.stops == 0)
        camera.configure(device: nil)
        #expect(camera.view == nil && second.stops == 1)
    }

    @Test func anUnknownCameraNeverStartsTheNativePreview() async {
        let route = NativePreparationCameraRoute()
        #expect(await !route.start(device: UUID().uuidString))
    }

    @Test func joiningDuringACameraSwitchStillWaitsForTheOriginalRelease() async {
        let first = PreviewRoute(), second = PreviewRoute()
        first.holdsStop = true
        second.holdsPermission = true
        var routes = [first, second]
        let camera = CallPreparationCamera { routes.removeFirst() }
        let id = UUID()
        camera.bind(id)
        camera.configure(device: "front")
        camera.toggle(in: id) { true }
        #expect(await eventually { camera.view != nil })
        camera.configure(device: "external", resumePreview: { true })
        #expect(await eventually { second.permission != nil })
        var joined = false
        camera.join(id) { joined = true }
        second.permission?.resume(returning: true)
        second.permission = nil
        try? await Task.sleep(for: .milliseconds(20))
        #expect(camera.isJoining && !joined && second.devices.isEmpty)
        first.finishStop()
        #expect(await eventually { joined && !camera.isJoining })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func nativePreview(in view: NSView) -> AVCaptureVideoPreviewLayer? {
        if let preview = view.layer as? AVCaptureVideoPreviewLayer {
            return preview
        }
        return view.subviews.lazy.compactMap { nativePreview(in: $0) }.first
    }
}

@MainActor
private final class PreviewRoute: CallPreparationCameraRoute {
    var holdsPermission = false
    var holdsStop = false
    var permission: CheckedContinuation<Bool, Never>?
    var loss: (@MainActor @Sendable () -> Void)?
    var starts = 0
    var devices: [String] = []
    var stops = 0
    private var stopping: AsyncStream<Void>.Continuation?

    var view: AnyView {
        AnyView(Color.clear)
    }

    func authorize() async -> Bool {
        guard holdsPermission else { return true }
        return await withCheckedContinuation { permission = $0 }
    }

    func start(device id: String) async -> Bool {
        starts += 1
        devices.append(id)
        return true
    }

    func observeLoss(_ callback: @escaping @MainActor @Sendable () -> Void) {
        loss = callback
    }

    func stop() -> Task<Void, Never> {
        stops += 1
        guard holdsStop else { return Task {} }
        let (complete, signal) = AsyncStream<Void>.makeStream()
        stopping = signal
        return Task { for await _ in complete {} }
    }

    func finishStop() {
        stopping?.finish()
        stopping = nil
    }
}

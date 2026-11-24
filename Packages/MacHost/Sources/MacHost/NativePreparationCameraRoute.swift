import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// A display-only camera session. Its only connection is the OS preview layer.
@MainActor
final class NativePreparationCameraRoute: CallPreparationCameraRoute {
    private let capture = Capture()
    private lazy var layer = AVCaptureVideoPreviewLayer(session: capture.session)
    private var observers: [any NSObjectProtocol] = []

    var view: AnyView {
        AnyView(CameraPreviewSurface(preview: layer).id(ObjectIdentifier(layer)).scaleEffect(x: -1, y: 1))
    }

    func authorize() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start(device id: String) async -> Bool {
        layer.videoGravity = .resizeAspect
        return await capture.start(device: id)
    }

    func observeLoss(_ callback: @escaping @MainActor @Sendable () -> Void) {
        for name in [AVCaptureSession.didStopRunningNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: capture.session, queue: .main
            ) { _ in
                Task { @MainActor in callback() }
            })
        }
    }

    func stop() -> Task<Void, Never> {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        return capture.stop()
    }
}

private struct CameraPreviewSurface: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        PreviewView(preview: preview)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class PreviewView: NSView {
        let preview: AVCaptureVideoPreviewLayer

        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Init with a preview layer.")
        }

        override func makeBackingLayer() -> CALayer {
            preview
        }
    }
}

private final class Capture: @unchecked Sendable {
    let session = AVCaptureSession()
    private static let queue = DispatchQueue(label: "chat.kibble.prejoin-camera", qos: .userInitiated)
    /// Accessed only on the serial capture queue.
    private nonisolated(unsafe) static var active: ObjectIdentifier?

    func start(device id: String) async -> Bool {
        await withCheckedContinuation { reply in
            Self.queue.async {
                reply.resume(returning: self.startOnQueue(device: id))
            }
        }
    }

    private func startOnQueue(device id: String) -> Bool {
        guard Self.active == nil, !id.isEmpty, let device = NativeCallCameras.device(for: id),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        session.startRunning()
        if session.isRunning {
            Self.active = ObjectIdentifier(self)
            return true
        }
        session.removeInput(input)
        return false
    }

    func stop() -> Task<Void, Never> {
        let (completion, signal) = AsyncStream<Void>.makeStream()
        Self.queue.async {
            if Self.active == ObjectIdentifier(self) {
                self.session.stopRunning()
                self.session.inputs.forEach(self.session.removeInput)
                Self.active = nil
            }
            signal.finish()
        }
        return Task { for await _ in completion {} }
    }
}

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend
@preconcurrency import ScreenCaptureKit

/// Capture is selected by macOS and stays local to this host. The presenter
/// peer has disabled audio and never asks for microphone/camera permission.
@MainActor
final class NativeCallScreenSharing: NSObject, CallScreenShareRouting {
    var ended: (() -> Void)?
    private let startPresenter: @Sendable (any CallMediaEngine) async throws -> Void
    private let stopPresenter: @Sendable () async -> Bool
    private var selection: CheckedContinuation<NativeScreenSelection?, any Error>?
    private var revision = 0
    private var cleanupConfirmed = true
    private var child: NativeCallMedia?
    private var stream: SCStream?
    private var output: NativeScreenOutput?
    private var pickerObserver: NativeScreenPickerObserver?

    init(
        start: @escaping @Sendable (any CallMediaEngine) async throws -> Void,
        stop: @escaping @Sendable () async -> Bool
    ) {
        startPresenter = start; stopPresenter = stop
        super.init()
    }

    func start() async throws -> Bool {
        guard child == nil, stream == nil, selection == nil else { throw CallMediaError.busy }
        cleanupConfirmed = true
        let revision = revision
        guard let selected = try await pick() else { return false }
        let filter = selected.filter
        try check(revision)
        let child = NativeCallMedia(presentation: true)
        self.child = child
        child.presentationEnded = { [weak self, weak child] in
            guard let self, let child, self.child === child else { return }
            suppress()
            ended?()
        }
        try await startPresenter(child)
        try check(revision)
        guard let video = child.video else { throw CallMediaError.negotiationFailed }
        let configuration = Self.configuration(filter)
        let output = NativeScreenOutput(source: video.source)
        self.output = output
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(
            label: "com.entersprite.kibble.presentation-frames", qos: .userInitiated
        ))
        try await stream.startCapture()
        try check(revision)
        output.enable()
        video.send(true)
        return true
    }

    func suppress() {
        revision += 1
        output?.disable()
        child?.video?.suppress()
        if let selection {
            self.selection = nil
            selection.resume(returning: nil)
        }
        removePicker()
    }

    func stop() async -> Bool {
        suppress()
        let stream = stream
        self.stream = nil
        if let stream {
            try? await stream.stopCapture()
        }
        output = nil
        child?.presentationEnded = nil
        child?.close()
        child = nil
        let confirmed = await stopPresenter()
        cleanupConfirmed = cleanupConfirmed && confirmed
        return cleanupConfirmed
    }

    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == revision else { throw CallMediaError.closed }
    }

    private func pick() async throws -> NativeScreenSelection? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        let revision = revision
        let observer = NativeScreenPickerObserver { [weak self] filter, failed in
            guard let self, self.revision == revision, let selection else { return }
            self.selection = nil
            if filter == nil {
                removePicker()
            }
            if failed {
                selection.resume(throwing: CallMediaError.connectionFailed)
            } else {
                selection.resume(returning: filter.map(NativeScreenSelection.init))
            }
        }
        pickerObserver = observer
        picker.add(observer)
        picker.isActive = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                selection = continuation
                picker.present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.revision == revision else { return }
                suppress()
            }
        }
    }

    private func removePicker() {
        guard let observer = pickerObserver else { return }
        pickerObserver = nil
        observer.cancel()
        SCContentSharingPicker.shared.remove(observer)
        SCContentSharingPicker.shared.isActive = false
    }

    private static func configuration(_ filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = filter.contentRect.size
        let ratio = size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
        configuration.width = Int(min(1920, 1080 * ratio)) / 2 * 2
        configuration.height = Int(Double(configuration.width) / ratio) / 2 * 2
        configuration.width = max(2, configuration.width)
        configuration.height = max(2, configuration.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        return configuration
    }
}

extension NativeCallScreenSharing: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, let stream = self.stream, ObjectIdentifier(stream) == identity else { return }
            suppress()
            ended?()
        }
    }
}

/// The capture queue forwards each complete buffer directly to WebRTC without
/// retaining it. The lock gates that forwarding during immediate local stop.
private final class NativeScreenOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let lock = NSLock()
    private var enabled = false

    init(source: LKRTCVideoSource) {
        self.source = source
        capturer = LKRTCVideoCapturer(delegate: source)
    }

    func enable() {
        lock.lock(); enabled = true; lock.unlock()
    }

    func disable() {
        lock.lock(); enabled = false; lock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              )
              as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixel = sampleBuffer.imageBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = LKRTCVideoFrame(
            buffer: LKRTCCVPixelBuffer(pixelBuffer: pixel),
            rotation: ._0,
            timeStampNs: CMTimeConvertScale(
                timestamp,
                timescale: 1_000_000_000,
                method: .default
            ).value
        )
        source.capturer(capturer, didCapture: frame)
    }
}

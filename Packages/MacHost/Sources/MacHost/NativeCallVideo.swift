import AVFoundation
import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

@MainActor
final class NativeCallVideo: CallCameraRouting {
    let track: LKRTCVideoTrack
    let receivers: [LKRTCRtpTransceiver]
    var receiver: LKRTCRtpTransceiver {
        receivers[0]
    }

    let capturer: LKRTCCameraVideoCapturer
    let source: LKRTCVideoSource
    private let factory: LKRTCPeerConnectionFactory
    private var closed = false
    var activeDevice = ""
    var announcement: (@Sendable (Bool) async throws -> Void)?

    init(factory: LKRTCPeerConnectionFactory, peer: LKRTCPeerConnection, presentation: Bool = false) throws {
        self.factory = factory
        source = presentation ? factory.videoSource(forScreenCast: true) : factory.videoSource()
        track = factory.videoTrack(with: source, trackId: UUID().uuidString)
        track.isEnabled = false
        capturer = LKRTCCameraVideoCapturer(delegate: source)
        let sending = LKRTCRtpTransceiverInit()
        sending.direction = .sendRecv
        sending.streamIds = [UUID().uuidString]
        let receiving = LKRTCRtpTransceiverInit()
        receiving.direction = .recvOnly
        guard let sender = peer.addTransceiver(with: track, init: sending)
        else { throw CallMediaError.negotiationFailed }
        var receivers: [LKRTCRtpTransceiver] = []
        for _ in 0 ..< (presentation ? 1 : 8) {
            guard let receiver = peer.addTransceiver(of: .video, init: receiving) else {
                throw CallMediaError.negotiationFailed
            }
            receivers.append(receiver)
        }
        self.receivers = receivers
        let codecs = factory.rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo).codecs.filter {
            ["video/vp8", "video/rtx"].contains($0.mimeType.lowercased())
        }
        guard codecs.contains(where: { $0.mimeType.lowercased() == "video/vp8" })
        else { throw CallMediaError.negotiationFailed }
        try sender.setCodecPreferences(codecs, error: ())
        for receiver in receivers {
            try receiver.setCodecPreferences(codecs, error: ())
        }
    }

    func devices() -> [CallCameraDevice] {
        LKRTCCameraVideoCapturer.captureDevices().map { CallCameraDevice(
            id: $0.uniqueID,
            name: $0.localizedName
        ) }
    }

    func start(_ id: String) async throws {
        guard !closed else { throw CameraFailure.closed }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraFailure.denied }
        try Task.checkCancellation()
        guard !closed else { throw CameraFailure.closed }
        suppress()
        await stop()
        try Task.checkCancellation()
        guard !closed else { throw CameraFailure.closed }
        let devices = LKRTCCameraVideoCapturer.captureDevices()
        guard let device = id.isEmpty ? devices.first : devices.first(where: { $0.uniqueID == id })
        else { throw CameraFailure.unavailable }
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        let eligible = formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > 0 && size.height > 0 && format.videoSupportedFrameRateRanges
                .contains { $0.maxFrameRate >= 15 }
        }
        guard let format = eligible.min(by: { Self.cost($0) < Self.cost($1) })
        else { throw CameraFailure.unavailable }
        let maximum = format.videoSupportedFrameRateRanges.filter { $0.minFrameRate <= 30 }
            .map(\.maxFrameRate).max() ?? 15
        let fps = Int(min(30, maximum))
        source.adaptOutputFormat(toWidth: 1280, height: 720, fps: Int32(fps))
        activeDevice = device.uniqueID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            capturer.startCapture(with: device, format: format, fps: fps) { error in
                if error != nil {
                    continuation.resume(throwing: CameraFailure.unavailable)
                } else {
                    continuation.resume()
                }
            }
        }
        guard !closed, !Task.isCancelled else {
            await stop()
            throw CameraFailure.closed
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in capturer.stopCapture { continuation.resume() } }
    }

    func suppress() {
        track.isEnabled = false
    }

    func send(_ enabled: Bool) {
        track.isEnabled = enabled && !closed
    }

    func announce(_ enabled: Bool) async throws {
        guard !closed, let announcement else { throw CameraFailure.closed }
        try await announcement(enabled)
        guard !closed else { throw CameraFailure.closed }
    }

    func close() {
        closed = true
        announcement = nil
        suppress()
        for receiver in receivers {
            receiver.receiver.track?.isEnabled = false
        }
        capturer.stopCapture()
    }

    private static func cost(_ format: AVCaptureDevice.Format) -> Int64 {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(Int64(size.width) * Int64(size.height) - 921_600)
    }
}

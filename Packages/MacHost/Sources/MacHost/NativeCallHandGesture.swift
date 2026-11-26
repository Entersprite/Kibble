import CoreVideo
import Foundation
import ImageIO
@preconcurrency import LiveKitWebRTC
import Observation
import Synchronization

@MainActor
@Observable
final class NativeCallHandGesture {
    typealias Detect = @Sendable (CVPixelBuffer, CGImagePropertyOrientation) -> Bool

    private(set) var progress: Double?
    @ObservationIgnored private var call: UUID?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var cadence = HandGestureCadence()
    @ObservationIgnored private var track: LKRTCVideoTrack?
    @ObservationIgnored private var cameraID: String?
    @ObservationIgnored private var renderer: HandGestureRenderer?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var raise: (() -> Void)?
    @ObservationIgnored private var isSpeaking: (() async -> Bool)?
    private let detect: Detect

    init(detect: @escaping Detect = NativeHandPose.detect(in:orientation:)) {
        self.detect = detect
    }

    func configure(
        call: UUID, track: LKRTCVideoTrack?, cameraID: String? = nil,
        isSpeaking: (() async -> Bool)?, raise: @escaping () -> Void
    ) {
        if self.call != call {
            stop()
            self.call = call
            cadence = HandGestureCadence()
        }
        guard let track else { stop(); return }
        self.raise = raise
        self.isSpeaking = isSpeaking
        guard self.track !== track || self.cameraID != cameraID else { return }
        stop()
        self.raise = raise
        self.isSpeaking = isSpeaking
        self.track = track
        self.cameraID = cameraID
        let epoch = epoch
        let renderer = HandGestureRenderer(detect: detect) { [weak self] detected, at in
            Task { @MainActor [weak self] in
                self?.receive(detected, at: at, epoch: epoch)
            }
        }
        self.renderer = renderer
        track.add(renderer)
    }

    func stop() {
        guard track != nil else { return }
        epoch = UUID()
        completion?.cancel()
        completion = nil
        renderer?.stop()
        if let renderer {
            track?.remove(renderer)
        }
        renderer = nil
        track = nil
        cameraID = nil
        raise = nil
        isSpeaking = nil
        cadence.clearProgress()
        if progress != nil {
            progress = nil
        }
    }

    private func receive(_ detected: Bool, at time: ContinuousClock.Instant, epoch: UUID) {
        guard self.epoch == epoch, track?.isEnabled == true, completion == nil else { return }
        let completed = cadence.receive(detected, at: time)
        progress = completed ? 1 : cadence.progress
        guard completed else { return }
        cadence.clearProgress()
        completion = Task { [weak self] in
            guard let self else { return }
            let speaking = await isSpeaking?() ?? false
            guard !Task.isCancelled, self.epoch == epoch else { return }
            completion = nil
            progress = nil
            if !speaking, track?.isEnabled == true {
                raise?()
            }
        }
    }
}

struct HandGestureCadence {
    private var streak = 0
    private var peak = 0
    private var lastSample: ContinuousClock.Instant?
    private var cooldown: ContinuousClock.Instant?
    private var awaitingRelease = false

    var progress: Double? {
        peak > 0 ? Double(peak) / 8 : nil
    }

    mutating func clearProgress() {
        streak = 0
        peak = 0
        lastSample = nil
    }

    mutating func receive(_ detected: Bool, at time: ContinuousClock.Instant) -> Bool {
        if !detected {
            awaitingRelease = false
        }
        guard !awaitingRelease, cooldown.map({ time >= $0 }) ?? true else { return false }
        if let lastSample, time - lastSample > .milliseconds(500) {
            clearProgress()
        }
        lastSample = time
        streak = max(0, streak + (detected ? 1 : -1))
        peak = streak == 0 ? 0 : max(peak, streak)
        guard streak == 8 else { return false }
        cooldown = time + .seconds(3)
        awaitingRelease = true
        return true
    }
}

private final class HandGestureRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private struct Admission {
        var stopped = false
        var pending = false
        var next = ContinuousClock.Instant.now
    }

    private struct Sample: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
    }

    private let admission = Mutex(Admission())
    private static let work = DispatchQueue(label: "chat.kibble.hand-pose", qos: .userInitiated)
    private let detect: NativeCallHandGesture.Detect
    private let receive: @Sendable (Bool, ContinuousClock.Instant) -> Void

    init(
        detect: @escaping NativeCallHandGesture.Detect,
        receive: @escaping @Sendable (Bool, ContinuousClock.Instant) -> Void
    ) {
        self.detect = detect
        self.receive = receive
    }

    func stop() {
        admission.withLock { $0.stopped = true }
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame, let buffer = frame.buffer as? LKRTCCVPixelBuffer else { return }
        let now = ContinuousClock.Instant.now
        let entered = admission.withLock { state in
            guard !state.stopped, !state.pending, now >= state.next else { return false }
            state.pending = true
            state.next = now + .milliseconds(125)
            return true
        }
        guard entered else { return }
        let sample = Sample(
            buffer: buffer.pixelBuffer,
            orientation: Self.orientation(Int(frame.rotation.rawValue))
        )
        Self.work.async { [weak self] in
            guard let self, admission.withLock({ !$0.stopped }) else { return }
            let detected = detect(sample.buffer, sample.orientation)
            let isCurrent = admission.withLock { state in
                state.pending = false
                return !state.stopped
            }
            if isCurrent {
                receive(detected, now)
            }
        }
    }

    private static func orientation(_ rotation: Int) -> CGImagePropertyOrientation {
        switch rotation {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }
}

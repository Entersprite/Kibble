import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import LiveKitWebRTC

/// Capture-only ADM for the presentation peer. It never opens an audio device
/// or plays received audio. ScreenCaptureKit owns consent and the selected source.
/// The lock owns all state; a single bounded latest packet crosses to ADM's thread.
final class NativePresentationAudioDevice: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var delegate: (any LKRTCAudioDeviceDelegate)?
    private var initialized = false
    private var recording = false
    private var playing = false
    private var enabled = false
    private var queued = false
    private var generation = UUID()
    private var pending: Data?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true
    )!

    var deviceInputSampleRate: Double {
        48000
    }

    var inputIOBufferDuration: TimeInterval {
        0.01
    }

    var inputNumberOfChannels: Int {
        2
    }

    var inputLatency: TimeInterval {
        0
    }

    var deviceOutputSampleRate: Double {
        48000
    }

    var outputIOBufferDuration: TimeInterval {
        0.01
    }

    var outputNumberOfChannels: Int {
        2
    }

    var outputLatency: TimeInterval {
        0
    }

    var isInitialized: Bool {
        lock.withLock { initialized }
    }

    var isRecordingInitialized: Bool {
        true
    }

    var isPlayoutInitialized: Bool {
        true
    }

    var isRecording: Bool {
        lock.withLock { recording }
    }

    var isPlaying: Bool {
        lock.withLock { playing }
    }

    func initialize(with delegate: any LKRTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            guard !initialized else { return false }
            generation = UUID()
            queued = false
            self.delegate = delegate
            initialized = true
            return true
        }
    }

    func terminateDevice() -> Bool {
        lock.withLock {
            enabled = false; recording = false; playing = false
            pending = nil; delegate = nil; initialized = false
            queued = false; generation = UUID()
            converter = nil; inputFormat = nil
            return true
        }
    }

    func initializePlayout() -> Bool {
        true
    }

    func startPlayout() -> Bool {
        lock.withLock { playing = true; return true }
    }

    func stopPlayout() -> Bool {
        lock.withLock { playing = false; return true }
    }

    func initializeRecording() -> Bool {
        true
    }

    func startRecording() -> Bool {
        lock.withLock { recording = true; return true }
    }

    func stopRecording() -> Bool {
        lock.withLock { recording = false; pending = nil; return true }
    }

    func enable() {
        lock.withLock { enabled = true }
    }

    func suppress() {
        lock.withLock { enabled = false; pending = nil }
    }

    /// Called only by the serial SCK audio queue. Reject unexpected/unbounded
    /// formats instead of retaining captured buffers or allowing an audio backlog.
    func receive(_ sample: CMSampleBuffer) {
        let target: (any LKRTCAudioDeviceDelegate, UUID)? = lock.withLock {
            guard enabled, recording, sample.isValid,
                  let description = sample.formatDescription else { return nil }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard (1 ... 4800).contains(frames) else { return nil }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate == 48000, format.channelCount == 2,
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let output = AVAudioPCMBuffer(
                      pcmFormat: outputFormat,
                      frameCapacity: AVAudioFrameCount(frames)
                  )
            else { return nil }
            input.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
            ) == noErr else { return nil }
            if inputFormat != format {
                inputFormat = format
                converter = AVAudioConverter(from: format, to: outputFormat)
            }
            guard let converter else { return nil }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow; return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            guard error == nil, status != .error, output.frameLength > 0,
                  let bytes = output.audioBufferList.pointee.mBuffers.mData else { return nil }
            pending = Data(bytes: bytes, count: Int(output.frameLength) * 4)
            guard !queued, let delegate else { return nil }
            queued = true
            return (delegate, generation)
        }
        if let (delegate, epoch) = target {
            delegate.dispatchAsync { [weak self] in self?.deliverPending(epoch: epoch) }
        }
    }

    private func deliverPending(epoch: UUID) {
        lock.withLock {
            guard epoch == generation else { return }
            queued = false
            guard enabled, recording, let delegate, let data = pending else { pending = nil; return }
            pending = nil
            // Every delivery runs on the same native ADM thread. Holding the
            // gate through delivery makes suppress() a synchronous capture fence.
            data.withUnsafeBytes { bytes in
                var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(data.count),
                    mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)
                ))
                var flags: AudioUnitRenderActionFlags = []
                var timestamp = AudioTimeStamp()
                timestamp.mFlags = .hostTimeValid
                timestamp.mHostTime = mach_absolute_time()
                _ = delegate.deliverRecordedData(
                    &flags,
                    &timestamp,
                    0,
                    UInt32(data.count / 4),
                    &buffer,
                    nil,
                    nil
                )
            }
        }
    }
}

import Accelerate
import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

@MainActor
final class NativePreparationAudio: CallPreparationAudioRoute {
    private let microphone = MicrophoneMeter()
    private let speaker = NativeCallSpeakerPlayback()

    func authorizeMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startMicrophone(device uid: String) async -> Bool {
        await microphone.start(device: uid)
    }

    var microphoneLevel: Double? {
        microphone.level
    }

    func stopMicrophone() -> Task<Void, Never> {
        microphone.stop()
    }

    func playSpeaker(device uid: String, completion: @escaping (Bool) -> Void) throws {
        try speaker.play(device: uid, completion: completion)
    }

    func stopSpeaker() {
        speaker.stop()
    }
}

private final class MicrophoneMeter: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "chat.kibble.prejoin-microphone", qos: .userInitiated)
    // Engine configuration and reservation are confined to the serial queue.
    private nonisolated(unsafe) static var active: ObjectIdentifier?
    private let engine = AVAudioEngine()
    private var observer: (any NSObjectProtocol)?
    private let lost = Atomic(false)
    private let levelPower = Atomic<Float>(0)

    var level: Double? {
        guard !lost.load(ordering: .relaxed) else { return nil }
        return MicrophoneLevel.normalized(power: levelPower.load(ordering: .relaxed))
    }

    func start(device uid: String) async -> Bool {
        await withCheckedContinuation { reply in
            Self.queue.async {
                reply.resume(returning: self.startOnQueue(device: uid))
            }
        }
    }

    private func startOnQueue(device uid: String) -> Bool {
        guard Self.active == nil, let device = try? AudioHardwareSystem.shared.device(forUID: uid),
              let streams = try? device.streams, streams.contains(where: { (try? $0.direction) == .input })
        else { return false }
        let input = engine.inputNode
        guard selectInput(device.id, on: input) else { return false }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate.isFinite,
              (8000 ... 384_000).contains(format.sampleRate),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return false }
        do {
            try installTap(input, frames: AVAudioFrameCount(format.sampleRate / 8))
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            guard inputDevice(input) == device.id else {
                engine.stop()
                input.removeTap(onBus: 0)
                return false
            }
        } catch {
            return false
        }
        Self.active = ObjectIdentifier(self)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.lost.store(true, ordering: .relaxed)
        }
        return true
    }

    private func selectInput(_ id: AudioDeviceID, on input: AVAudioInputNode) -> Bool {
        withAudioUnit(input) { unit in
            guard let unit else { return false }
            var target = id
            return AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &target, UInt32(MemoryLayout<AudioDeviceID>.size)
            ) == noErr
        }
    }

    private func inputDevice(_ input: AVAudioInputNode) -> AudioDeviceID? {
        withAudioUnit(input) { unit in
            guard let unit else { return nil }
            var current = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size
            )
            return status == noErr ? current : nil
        }
    }

    private func withAudioUnit<Result>(_ input: AVAudioInputNode, _ body: (AudioUnit?) -> Result) -> Result {
        if #available(macOS 27.0, *) {
            return input.withAudioUnit { body($0) }
        }
        return body(input.audioUnit)
    }

    private func installTap(_ input: AVAudioInputNode, frames: AVAudioFrameCount) throws {
        if #available(macOS 27.0, *) {
            try input.installAudioTap(onBus: 0, bufferSize: frames, format: nil) { [weak self] buffer, _ in
                let power = buffer.withUnsafeAudioBufferList {
                    MicrophoneLevel.power(frameCount: buffer.frameLength, channels: $0)
                }
                self?.levelPower.store(power, ordering: .relaxed)
            }
        } else {
            input.installTap(onBus: 0, bufferSize: frames, format: nil) { [weak self] buffer, _ in
                let power = MicrophoneLevel.power(
                    frameCount: Int(buffer.frameLength),
                    channels: buffer.audioBufferList
                )
                self?.levelPower.store(power, ordering: .relaxed)
            }
        }
    }

    func stop() -> Task<Void, Never> {
        let (done, signal) = AsyncStream<Void>.makeStream()
        Self.queue.async {
            if Self.active == ObjectIdentifier(self) {
                if let observer = self.observer {
                    NotificationCenter.default.removeObserver(observer)
                    self.observer = nil
                }
                self.engine.stop()
                self.engine.inputNode.removeTap(onBus: 0)
                Self.active = nil
            }
            signal.finish()
        }
        return Task { for await _ in done {} }
    }
}

enum MicrophoneLevel {
    static func power(frameCount: Int, channels list: UnsafePointer<AudioBufferList>) -> Float {
        let channels = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        return channels.reduce(0) { maximum, channel in
            guard let data = channel.mData else { return maximum }
            let frames = min(frameCount, Int(channel.mDataByteSize) / MemoryLayout<Float>.stride)
            guard frames > 0 else { return maximum }
            var power: Float = 0
            vDSP_measqv(data.assumingMemoryBound(to: Float.self), 1, &power, vDSP_Length(frames))
            return max(maximum, power)
        }
    }

    static func normalized(power: Float) -> Double {
        guard power.isFinite, power > 0 else { return 0 }
        let decibels = 10 * log10(Double(power))
        return min(1, max(0, (decibels + 55) / 55))
    }
}

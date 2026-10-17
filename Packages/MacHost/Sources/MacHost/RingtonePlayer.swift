import AVFoundation
import Foundation

/// The sound an incoming call rings with: Kibble's own, or a file the person
/// chose in Settings › Calls.
enum Ringtone {
    /// Kibble's own: one bar that loops into itself.
    static let bundled = Bundle.module.url(forResource: "Kibble", withExtension: "aif")

    /// The whole file is held in memory while it rings, so a long one is
    /// refused rather than kept there; the iPhone's own ringtone limit.
    static let maximumDuration: TimeInterval = 40

    enum Failure: Error, Equatable {
        case unreadable
        case empty
        case tooLong
    }

    /// The whole file as one buffer. Decoding also checks that a chosen file
    /// is audio Kibble can play.
    static func decode(_ url: URL) throws(Failure) -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw .unreadable
        }
        let format = file.processingFormat
        guard file.length > 0 else { throw .empty }
        guard Double(file.length) / format.sampleRate <= maximumDuration else { throw .tooLong }
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let whole = buffer.floatChannelData, let part = chunk.floatChannelData
        else { throw .unreadable }
        // One read can return less than it was asked for (44,032 of a float
        // file's 44,100 frames), which would loop a little short; read on to
        // the end.
        while buffer.frameLength < capacity {
            do {
                try file.read(into: chunk)
            } catch {
                throw .unreadable
            }
            guard chunk.frameLength > 0 else { break }
            let count = min(chunk.frameLength, capacity - buffer.frameLength)
            for channel in 0 ..< Int(format.channelCount) {
                (whole[channel] + Int(buffer.frameLength)).update(from: part[channel], count: Int(count))
            }
            buffer.frameLength += count
        }
        guard buffer.frameLength > 0 else { throw .empty }
        return buffer
    }
}

@MainActor
protocol RingtonePlaying: AnyObject {
    func play(_ url: URL, loops: Bool) throws
    func stop()
}

/// Plays a ringtone through Kibble's own audio engine, at the output volume:
/// looped without a pause while a call rings, or once as a preview.
///
/// The decoded buffer loops on itself, so the repeat is seamless whatever the
/// file's format; a player that streams from the file can leave a gap at each
/// repeat of a compressed one. Lives for the process, like `CallRinger`.
@MainActor
final class RingtonePlayer: RingtonePlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var looping: AVAudioPCMBuffer?

    init() {
        engine.attach(node)
        // A new output device (headphones, a changed default) stops the
        // engine; a ring carries on there.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeLoop() }
        }
    }

    func play(_ url: URL, loops: Bool) throws {
        let buffer = try Ringtone.decode(url)
        stop()
        try start(buffer, loops: loops)
        looping = loops ? buffer : nil
    }

    func stop() {
        looping = nil
        node.stop()
        engine.stop()
    }

    private func start(_ buffer: AVAudioPCMBuffer, loops: Bool) throws {
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        try engine.start()
        node.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [])
        node.play()
    }

    private func resumeLoop() {
        guard let looping else { return }
        node.stop()
        do {
            try start(looping, loops: true)
        } catch {
            self.looping = nil
        }
    }
}

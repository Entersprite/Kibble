import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

struct NativePresentationAudioDeviceTests {
    @Test func captureIsExplicitBoundedAndSuppressedBeforeQueuedDelivery() throws {
        let device = NativePresentationAudioDevice()
        let delegate = PresentationAudioDelegate()
        #expect(device.initialize(with: delegate))
        #expect(device.startRecording())
        let sample = try sample()
        device.receive(sample)
        #expect(delegate.queued == 0)
        device.enable()
        for _ in 0 ..< 100 {
            device.receive(sample)
        }
        #expect(delegate.queued == 1)
        device.suppress()
        delegate.drain()
        #expect(delegate.deliveries == 0)
        device.enable()
        device.receive(sample)
        delegate.drain()
        #expect(delegate.deliveries == 1)
        #expect(delegate.frames == 480)
        #expect(delegate.channels == 2)
        #expect(delegate.bytes == 1920)
        #expect(delegate.leadingSamples.count == 4)
        #expect(delegate.leadingSamples[0] > 7000)
        #expect(delegate.leadingSamples[1] < -7000)
        #expect(device.terminateDevice())
        device.receive(sample)
        delegate.drain()
        #expect(delegate.deliveries == 1)
        #expect(!device.isRecording)
    }

    private func sample() throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try #require(buffer.floatChannelData)
        for index in 0 ..< 480 {
            channels[0][index] = 0.25; channels[1][index] = -0.25
        }
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ) == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        #expect(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr)
        let value = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
            value, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ) == noErr)
        return value
    }
}

private final class PresentationAudioDelegate: NSObject, LKRTCAudioDeviceDelegate, @unchecked Sendable {
    private var blocks: [@Sendable () -> Void] = []
    private(set) var deliveries = 0, frames: UInt32 = 0, channels: UInt32 = 0, bytes: UInt32 = 0
    private(set) var leadingSamples: [Int16] = []
    var queued: Int {
        blocks.count
    }

    var preferredInputSampleRate: Double {
        48000
    }

    var preferredOutputSampleRate: Double {
        48000
    }

    var preferredInputIOBufferDuration: TimeInterval {
        0.01
    }

    var preferredOutputIOBufferDuration: TimeInterval {
        0.01
    }

    var deliverRecordedData: LKRTCAudioDeviceDeliverRecordedDataBlock {
        { [weak self] _, _, _, frames, buffer, _, _ in
            guard let self, let buffer else { return noErr }
            deliveries += 1
            self.frames = frames
            channels = buffer.pointee.mBuffers.mNumberChannels
            bytes = buffer.pointee.mBuffers.mDataByteSize
            if let data = buffer.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) {
                leadingSamples = Array(UnsafeBufferPointer(start: data, count: 4))
            }
            return noErr
        }
    }

    var getPlayoutData: LKRTCAudioDeviceGetPlayoutDataBlock {
        { _, _, _, _, _ in noErr }
    }

    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping @Sendable () -> Void) {
        blocks.append(block)
    }

    func dispatchSync(_ block: @Sendable () -> Void) {
        block()
    }

    func drain() {
        let pending = blocks
        blocks = []
        for block in pending {
            block()
        }
    }
}

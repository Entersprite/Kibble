import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

@MainActor
struct NativeCallHandGestureTests {
    @Test func anOpenPalmBesideTheShoulderQualifies() {
        let body = NativeHandPose.Body(
            leftShoulder: CGPoint(x: 0.37, y: 0.48),
            rightShoulder: CGPoint(x: 0.63, y: 0.48),
            nose: CGPoint(x: 0.5, y: 0.67)
        )
        #expect(NativeHandPose.isRaised(sample(x: 0.75), beside: body))
        #expect(!NativeHandPose.isRaised(sample(x: 0.54), beside: body))
        #expect(!NativeHandPose.isRaised(sample(x: 0.75, height: 0.21), beside: body))
        #expect(!NativeHandPose.isRaised(sample(x: 0.75, open: false), beside: body))
    }

    @Test func aGestureMustHoldAndReleaseBeforeItCanRaiseAgain() {
        var cadence = HandGestureCadence()
        let start = ContinuousClock.Instant.now
        func receive(_ raised: Bool, at tick: Int) -> Bool {
            cadence.receive(raised, at: start + .milliseconds(tick * 125))
        }
        for tick in 0 ..< 7 {
            #expect(!receive(true, at: tick))
        }
        #expect(cadence.progress == 7.0 / 8.0)
        #expect(receive(true, at: 7))
        cadence.clearProgress()
        for tick in 8 ... 40 {
            #expect(!receive(true, at: tick))
        }
        #expect(!receive(false, at: 41))
        #expect(!receive(true, at: 42))
        #expect(!receive(true, at: 50))
        #expect(cadence.progress == 1.0 / 8.0)
    }

    @Test func aClosedCameraRouteRetiresItsGestureBeforeTheSpeechCheckReturns() async throws {
        let detector = NativeCallHandGesture(detect: { _, _ in true })
        let factory = LKRTCPeerConnectionFactory()
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "local-test-camera")
        let capturer = LKRTCVideoCapturer(delegate: source)
        let pixel = try blankBuffer()
        var isChecking = false
        var raises = 0
        detector.configure(
            call: UUID(), track: track,
            isSpeaking: {
                isChecking = true
                try? await Task.sleep(for: .seconds(1))
                return false
            },
            raise: { raises += 1 }
        )
        for index in 0 ..< 24 {
            source.capturer(capturer, didCapture: LKRTCVideoFrame(
                buffer: LKRTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0,
                timeStampNs: Int64(index) * 150_000_000
            ))
            if isChecking {
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(isChecking)
        detector.stop()
        await Task.yield()
        #expect(raises == 0 && detector.progress == nil)
    }

    @Test func visionRejectsAnEmptyFrame() throws {
        #expect(try !NativeHandPose.detect(in: blankBuffer(), orientation: .up))
    }

    private func sample(x center: CGFloat, height: CGFloat = 0.57, open: Bool = true) -> NativeHandPose
        .Sample {
        NativeHandPose.Sample(
            wrist: CGPoint(x: center, y: height - 0.08), palm: CGPoint(x: center, y: height),
            fingers: (0 ..< 4).map { index in
                let horizontal = center + CGFloat(index - 1) * 0.012
                return NativeHandPose.Finger(
                    tip: CGPoint(x: horizontal, y: height + (open ? 0.16 : 0.04)),
                    joint: CGPoint(x: horizontal, y: height + 0.1)
                )
            }
        )
    }

    private func blankBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 160, 160, kCVPixelFormatType_32BGRA, nil, &result) ==
            kCVReturnSuccess)
        let pixel = try #require(result)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 0, CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }
}

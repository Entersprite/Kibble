import Foundation
import Testing
@testable import MacHost

@Suite(.timeLimit(.minutes(1)))
struct NativeMediaDiagnosticWaiterTests {
    @Test func timeoutBoundsAnSDKCallbackThatNeverArrives() async {
        let waiter = NativeMediaDiagnosticWaiter()
        let result = await withCheckedContinuation { continuation in
            waiter.install(continuation)
            waiter.armTimeout(.milliseconds(5))
        }
        #expect(result == nil)
        #expect(!waiter.isPending)
        waiter.finish(NativeAudioStatistics())
        #expect(!waiter.isPending)
    }

    @Test func cancellationBeforeContinuationInstallationStillResolvesExactlyOnce() async {
        let waiter = NativeMediaDiagnosticWaiter()
        waiter.finish(nil)
        let result = await withCheckedContinuation { waiter.install($0) }
        #expect(result == nil)
        waiter.armTimeout(.milliseconds(5))
        waiter.finish(NativeAudioStatistics())
        #expect(!waiter.isPending)
    }

    @Test func successfulCallbackWinsAndLateTimeoutOrCallbacksCannotReplaceIt() async {
        let waiter = NativeMediaDiagnosticWaiter()
        var sample = NativeAudioStatistics()
        sample.add(type: "outbound-rtp", values: [
            "kind": "audio" as NSString, "packetsSent": 12 as NSNumber, "bytesSent": 120 as NSNumber
        ])
        let result = await withCheckedContinuation { continuation in
            waiter.install(continuation)
            waiter.armTimeout(.seconds(1))
            waiter.finish(sample)
            waiter.finish(nil)
        }
        #expect(result?.outbound.packetsValue == 12)
        #expect(!waiter.isPending)
    }

    @MainActor
    @Test func collectingWithoutAPeerNeverRequestsMicrophoneOrPreparesHardware() async {
        var requested = false
        let media = NativeCallMedia(microphoneAccess: { requested = true; return false })
        let lines = await media.diagnosticReport()
        #expect(lines == ["Native media diagnostics: no peer"])
        #expect(!requested)
        media.close()
        #expect(await media.diagnosticReport() == ["Native media diagnostics: no peer"])
    }
}

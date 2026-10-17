import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

@MainActor
struct CallScreenShareControllerTests {
    @Test func captureRequiresExplicitActionAndStopSuppressesBeforeCleanup() async {
        let controller = CallScreenShareController(), route = ScreenRoute()
        _ = controller.install(route)
        #expect(route.starts == 0)
        controller.toggle()
        await wait { controller.state?.phase == .sharing }
        #expect(route.sending)
        route.holdStop = true
        controller.toggle()
        #expect(!route.sending)
        #expect(controller.state?.phase == .stopping)
        await wait { route.stops == 1 }
        route.finishStop()
        await wait { controller.state?.phase == .idle }
        controller.clear()
    }

    @Test func thePreviewIsPublishedOnlyWhileSharingAndGoesWithStop() async {
        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "preview")
        let controller = CallScreenShareController(), route = ScreenRoute()
        route.preview = track
        _ = controller.install(route)
        #expect(controller.preview == nil)
        route.holdStart = true
        controller.toggle()
        await wait { route.startContinuation != nil }
        // Choosing in the picker is not sharing yet.
        #expect(controller.preview == nil)
        route.finishStart()
        await wait { controller.state?.phase == .sharing }
        #expect(controller.preview === track)
        route.holdStop = true
        controller.toggle()
        #expect(controller.preview == nil)
        await wait { route.stops == 1 }
        route.finishStop()
        await wait { controller.state?.phase == .idle }
        controller.toggle()
        await wait { controller.state?.phase == .sharing }
        #expect(controller.preview === track)
        controller.clear()
        #expect(controller.preview == nil)
    }

    @Test func pickerCancellationAndStartFailureLeaveRetryAvailable() async {
        let controller = CallScreenShareController(), route = ScreenRoute()
        route.cancelPicker = true
        _ = controller.install(route)
        controller.toggle()
        await wait { route.starts == 1 && controller.state?.phase == .idle }
        #expect(!route.sending)
        route.cancelPicker = false; route.fail = true
        controller.toggle()
        await wait { controller.state?.notice != nil }
        #expect(!route.sending)
        #expect(route.stops == 1)
        route.fail = false
        controller.toggle()
        await wait { controller.state?.phase == .sharing }
        controller.clear()
    }

    @Test func cancelDuringStartSettlesLateCompletionWithoutSharing() async {
        let controller = CallScreenShareController(), route = ScreenRoute()
        route.holdStart = true
        _ = controller.install(route)
        controller.toggle()
        await wait { route.startContinuation != nil }
        controller.toggle()
        #expect(controller.state?.phase == .stopping)
        route.finishStart()
        await wait { controller.state?.phase == .idle }
        #expect(!route.sending)
        #expect(route.stops >= 1)
        controller.clear()
    }

    @Test func oldCompletionCannotChangeReplacementAndCaptureEndStopsCurrentShare() async {
        let controller = CallScreenShareController(), old = ScreenRoute(), next = ScreenRoute()
        old.holdStart = true
        let oldScope = controller.install(old)
        controller.toggle()
        await wait { old.startContinuation != nil }
        _ = controller.install(next)
        old.finishStart()
        await wait { old.stops >= 1 }
        #expect(!old.sending)
        #expect(controller.state?.phase == .idle)
        controller.clear(ifCurrent: oldScope)
        #expect(controller.state != nil)
        controller.toggle()
        await wait { controller.state?.phase == .sharing }
        next.confirmed = false
        next.ended?()
        #expect(!next.sending)
        await wait { controller.state?.phase == .idle }
        #expect(controller.state?.notice?.contains("hasn’t confirmed") == true)
        controller.clear()
    }

    @Test func queuedPickerFailureCannotReachCancelledObserverOrCompleteTwice() async {
        var oldResults = 0, currentResults = 0
        let old = NativeScreenPickerObserver { _, _ in oldResults += 1 }
        let current = NativeScreenPickerObserver { _, _ in currentResults += 1 }
        let error = NSError(domain: "synthetic", code: 1)
        old.contentSharingPickerStartDidFailWithError(error)
        old.cancel()
        current.contentSharingPickerStartDidFailWithError(error)
        current.contentSharingPickerStartDidFailWithError(error)
        await wait { currentResults == 1 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(oldResults == 0)
        #expect(currentResults == 1)
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0 ..< 2000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        #expect(condition())
    }
}

@MainActor
private final class ScreenRoute: CallScreenShareRouting {
    var ended: (() -> Void)?
    var preview: LKRTCVideoTrack?
    var starts = 0, stops = 0
    var sending = false, fail = false, cancelPicker = false, confirmed = true
    var holdStart = false, holdStop = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    func start() async throws -> Bool {
        starts += 1
        if holdStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        try Task.checkCancellation()
        if fail {
            throw ScreenFailure.failed
        }
        sending = !cancelPicker
        return !cancelPicker
    }

    func suppress() {
        sending = false
    }

    func stop() async -> Bool {
        stops += 1
        if holdStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        return confirmed
    }

    func finishStart() {
        startContinuation?.resume(); startContinuation = nil; holdStart = false
    }

    func finishStop() {
        stopContinuation?.resume(); stopContinuation = nil; holdStop = false
    }

    enum ScreenFailure: Error { case failed }
}

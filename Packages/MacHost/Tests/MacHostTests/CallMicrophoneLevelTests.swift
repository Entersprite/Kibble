import Foundation
import Testing
@testable import MacHost

@MainActor
extension CallAudioDeviceTests {
    @Test func anInputChangeDiscardsAReadingStillInFlight() async throws {
        let controller = CallAudioDeviceController()
        let route = NativeCallAudioRouting(hardware: FakeCallAudioHardware())
        defer { controller.clear(); route.close() }
        let (samples, sender) = AsyncStream<Double>.makeStream()
        defer { sender.finish() }
        var requested = false
        controller.install(route) {
            requested = true
            var iterator = samples.makeAsyncIterator()
            return await iterator.next()
        }
        try await settle(controller)
        let before = try #require(controller.microphoneLevelScope)
        let sample = Task { await controller.microphoneLevel(in: before) }
        for _ in 0 ..< 200 where !requested {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requested)
        controller.select("mic:usb", microphone: true)
        try await settle(controller)
        #expect(controller.microphoneLevelScope != before)
        sender.yield(0.3)
        sender.finish()
        let expiredLevel = await sample.value
        #expect(expiredLevel == nil)
    }

    @Test func microphoneLevelsPreserveSilenceAndRejectInvalidData() async throws {
        let controller = CallAudioDeviceController()
        let route = NativeCallAudioRouting(hardware: FakeCallAudioHardware())
        defer { controller.clear(); route.close() }
        var raw: Double? = 0
        controller.install(route) { raw }
        try await settle(controller)
        let scope = try #require(controller.microphoneLevelScope)
        #expect(await controller.microphoneLevel(in: scope) == 0)
        raw = 0.1
        let scaled = try #require(await controller.microphoneLevel(in: scope))
        #expect((0.63 ... 0.64).contains(scaled))
        raw = .nan
        #expect(await controller.microphoneLevel(in: scope) == nil)
        raw = 1.1
        #expect(await controller.microphoneLevel(in: scope) == nil)
        raw = nil
        #expect(await controller.microphoneLevel(in: scope) == nil)
    }
}

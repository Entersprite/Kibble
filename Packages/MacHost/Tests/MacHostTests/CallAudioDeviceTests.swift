import DesignSystem
import Foundation
import Synchronization
import Testing
@testable import MacHost

struct CallAudioDeviceTests {
    @MainActor
    @Test func failedSwitchRestoresControlsAndShowsFeedback() async throws {
        let hardware = FakeCallAudioHardware()
        hardware.state.withLock { $0.acceptsSelection = false }
        let route = NativeCallAudioRouting(hardware: hardware)
        let controller = CallAudioDeviceController()
        controller.install(route)
        for _ in 0 ..< 500 where controller.devices == nil {
            await Task.yield()
        }
        try #require(controller.devices != nil)
        controller.select("mic:usb", microphone: true)
        #expect(controller.devices?.isUpdating == true)
        for _ in 0 ..< 500 where controller.devices?.isUpdating == true {
            await Task.yield()
        }
        #expect(controller.devices?.isUpdating == false)
        #expect(controller.devices?.microphone == "")
        #expect(controller.devices?.notice == "Couldn’t switch audio devices. Please choose another device.")
        controller.clear()
        #expect(controller.devices == nil)
        route.close()
    }

    @Test func selectionUsesStableIDsAndDoesNotClaimAFailedSwitch() async {
        let hardware = FakeCallAudioHardware()
        let route = NativeCallAudioRouting(hardware: hardware)
        let initial = await route.snapshot()
        #expect(initial.microphone.isEmpty && initial.speaker.isEmpty)
        let selected = await route.select("mic:usb", microphone: true)
        #expect(selected)
        hardware.state.withLock { $0.acceptsSelection = false }
        let failed = await route.select("", microphone: true)
        #expect(!failed)
        let snapshot = await route.snapshot()
        #expect(snapshot.microphone == "mic:usb")
        #expect(snapshot.speaker.isEmpty)
        let invalid = await route.select("unknown-device", microphone: false)
        #expect(!invalid)
        let changes = hardware.state.withLock { $0.changes }
        #expect(changes == ["input:mic:usb", "input:"])
        route.close()
    }

    @Test func unplugFallsBackOnlyTheAffectedDirectionAndReportsIt() async {
        let hardware = FakeCallAudioHardware()
        let route = NativeCallAudioRouting(hardware: hardware)
        _ = await route.select("mic:usb", microphone: true)
        _ = await route.select("speaker:usb", microphone: false)
        hardware.state.withLock { $0.inputs = [] }
        let snapshot = await route.snapshot()
        #expect(snapshot.microphone.isEmpty)
        #expect(snapshot.speaker == "speaker:usb")
        #expect(snapshot.notice == "Microphone disconnected. Using System Default.")
        let changes = hardware.state.withLock { $0.changes }
        #expect(changes == ["input:mic:usb", "output:speaker:usb", "input:"])
        route.close()
    }

    @Test func failedUnplugFallbackKeepsTheUnavailableSelectionVisible() async {
        let hardware = FakeCallAudioHardware()
        let route = NativeCallAudioRouting(hardware: hardware)
        _ = await route.select("speaker:usb", microphone: false)
        hardware.state.withLock { $0.outputs = []; $0.acceptsSelection = false }
        let snapshot = await route.snapshot()
        #expect(snapshot.speaker == "speaker:usb")
        #expect(snapshot.speakers == [CallAudioDevice(id: "speaker:usb", name: "Unavailable speaker")])
        #expect(snapshot.notice == "Speaker unavailable. Choose another device.")
        route.close()
    }

    @Test func closedRouteCannotChangeOrRestartHardware() async {
        let hardware = FakeCallAudioHardware()
        let route = NativeCallAudioRouting(hardware: hardware)
        route.close()
        let selected = await route.select("mic:usb", microphone: true)
        let snapshot = await route.snapshot()
        #expect(!selected)
        #expect(snapshot.microphones.isEmpty)
        #expect(hardware.state.withLock { $0.changes.isEmpty })
    }

    @MainActor
    @Test func replacementRouteIgnoresLateSelectionAndOldEngineCleanup() async throws {
        let controller = CallAudioDeviceController()
        let old = HeldCallAudioRoute()
        let scope = controller.install(old)
        for _ in 0 ..< 300 where controller.devices == nil {
            await Task.yield()
        }
        try #require(controller.devices != nil)
        controller.select("mic:old", microphone: true)
        for _ in 0 ..< 300 where await old.isSelecting == false {
            await Task.yield()
        }
        let selecting = await old.isSelecting
        try #require(selecting)
        let hardware = FakeCallAudioHardware()
        let replacement = NativeCallAudioRouting(hardware: hardware)
        controller.install(replacement)
        controller.clear(ifCurrent: scope)
        await old.finish()
        for _ in 0 ..< 300 where controller.devices?.microphones.isEmpty != false {
            await Task.yield()
        }
        #expect(controller.devices?.microphones.first?.id == "mic:usb")
        #expect(controller.devices?.isUpdating == false)
        #expect(controller.devices?.microphone == "")
        controller.clear()
        replacement.close()
    }
}

private final class FakeCallAudioHardware: CallAudioHardware, Sendable {
    struct State {
        var inputs = [CallAudioDevice(id: "mic:usb", name: "USB Microphone")]
        var outputs = [CallAudioDevice(id: "speaker:usb", name: "USB Headphones")]
        var acceptsSelection = true
        var changes: [String] = []
    }

    let state = Mutex(State())

    func devices(microphone: Bool) -> [CallAudioDevice] {
        state.withLock { microphone ? $0.inputs : $0.outputs }
    }

    func select(_ id: String, microphone: Bool) -> Bool {
        state.withLock {
            $0.changes.append("\(microphone ? "input" : "output"):\(id)")
            return $0.acceptsSelection
        }
    }
}

private actor HeldCallAudioRoute: CallAudioRouting {
    private var continuation: CheckedContinuation<Bool, Never>?
    var isSelecting: Bool {
        continuation != nil
    }

    func snapshot() -> CallAudioDevices {
        CallAudioDevices(microphones: [], speakers: [], microphone: "mic:old")
    }

    func select(_: String, microphone _: Bool) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: true); continuation = nil
    }
}

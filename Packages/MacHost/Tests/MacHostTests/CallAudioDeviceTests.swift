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

    @MainActor
    @Test func chosenDevicesAreKeptAndUsedByTheNextCall() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        let first = CallAudioDeviceController(preferences: place.preferences())
        let firstRoute = NativeCallAudioRouting(hardware: FakeCallAudioHardware())
        first.install(firstRoute)
        try await settle(first)
        first.select("mic:usb", microphone: true)
        try await settle(first)
        first.select("speaker:usb", microphone: false)
        try await settle(first)
        first.clear()
        firstRoute.close()
        // The lasting name is saved, not the picker's per-session ID.
        #expect(place.preferences().microphone == "uid:mic:usb")
        #expect(place.preferences().speaker == "uid:speaker:usb")

        // After a relaunch or reconnection the same microphone has a new ID.
        let hardware = FakeCallAudioHardware()
        hardware.state.withLock {
            $0.inputs = [CallAudioDevice(id: "mic:usb-again", name: "USB Microphone")]
            $0.uids["mic:usb-again"] = "uid:mic:usb"
        }
        let next = CallAudioDeviceController(preferences: place.preferences())
        let route = NativeCallAudioRouting(hardware: hardware)
        next.install(route)
        try await settle(next)
        #expect(next.devices?.microphone == "mic:usb-again")
        #expect(next.devices?.speaker == "speaker:usb")
        #expect(next.devices?.notice == nil)
        #expect(hardware.state.withLock { $0.changes } == ["input:mic:usb-again", "output:speaker:usb"])
        next.clear()
        route.close()
    }

    /// A device the hardware cannot name lastingly is used for this call only.
    @MainActor
    @Test func aDeviceWithoutALastingNameIsNotKept() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        place.preferences().saveAudio("uid:old", microphone: true)
        let hardware = FakeCallAudioHardware()
        hardware.state.withLock { $0.unnamed = ["mic:usb"] }
        let controller = CallAudioDeviceController(preferences: place.preferences())
        let route = NativeCallAudioRouting(hardware: hardware)
        controller.install(route)
        try await settle(controller)
        controller.select("mic:usb", microphone: true)
        try await settle(controller)
        #expect(controller.devices?.microphone == "mic:usb")
        #expect(place.preferences().microphone == "")
        controller.clear()
        route.close()
    }

    /// A saved device that is not connected, or that refuses the switch, leaves
    /// the call on System Default with no error, and stays saved for later.
    @MainActor
    @Test func aMissingOrRefusingSavedDeviceFallsBackToSystemDefault() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        let preferences = place.preferences()
        preferences.saveAudio("uid:mic:gone", microphone: true)
        preferences.saveAudio("uid:speaker:usb", microphone: false)
        let hardware = FakeCallAudioHardware()
        hardware.state.withLock { $0.acceptsSelection = false }
        let controller = CallAudioDeviceController(preferences: preferences)
        let route = NativeCallAudioRouting(hardware: hardware)
        controller.install(route)
        try await settle(controller)
        #expect(controller.devices?.microphone == "")
        #expect(controller.devices?.speaker == "")
        #expect(controller.devices?.notice == nil)
        // The missing microphone is never asked for; the speaker was tried once.
        #expect(hardware.state.withLock { $0.changes } == ["output:speaker:usb"])
        #expect(place.preferences().microphone == "uid:mic:gone")
        #expect(place.preferences().speaker == "uid:speaker:usb")
        controller.clear()
        route.close()
    }

    @MainActor
    @Test func aRefusedSwitchIsNotSavedAndSystemDefaultForgetsTheChoice() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        let preferences = place.preferences()
        preferences.saveAudio("uid:mic:usb", microphone: true)
        let hardware = FakeCallAudioHardware()
        let controller = CallAudioDeviceController(preferences: preferences)
        let route = NativeCallAudioRouting(hardware: hardware)
        controller.install(route)
        try await settle(controller)
        hardware.state.withLock { $0.acceptsSelection = false }
        controller.select("speaker:usb", microphone: false)
        try await settle(controller)
        #expect(place.preferences().speaker == "")
        hardware.state.withLock { $0.acceptsSelection = true }
        controller.select("", microphone: true)
        try await settle(controller)
        #expect(controller.devices?.microphone == "")
        #expect(place.preferences().microphone == "")
        controller.clear()
        route.close()
    }

    /// Waits for the first snapshot, then for any selection to finish.
    @MainActor
    private func settle(_ controller: CallAudioDeviceController) async throws {
        for _ in 0 ..< 500 where controller.devices == nil || controller.devices?.isUpdating == true {
            await Task.yield()
        }
        try #require(controller.devices != nil)
        try #require(controller.devices?.isUpdating == false)
    }
}

/// A defaults suite of its own, so saved devices never leak between tests.
@MainActor
struct DevicePreferencesPlace {
    let suite = "CallDevicePreferencesTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func preferences() -> CallDevicePreferences {
        CallDevicePreferences(defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class FakeCallAudioHardware: CallAudioHardware, Sendable {
    struct State {
        var inputs = [CallAudioDevice(id: "mic:usb", name: "USB Microphone")]
        var outputs = [CallAudioDevice(id: "speaker:usb", name: "USB Headphones")]
        var acceptsSelection = true
        var changes: [String] = []
        /// Lasting names that differ from `uid:<id>`, as after a reconnection.
        var uids: [String: String] = [:]
        var unnamed: Set<String> = []
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

    func persistentID(of id: String) -> String? {
        state.withLock { $0.unnamed.contains(id) ? nil : $0.uids[id] ?? "uid:\(id)" }
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

    func persistentID(of _: String, microphone _: Bool) -> String? {
        nil
    }

    func restore(_: String, microphone _: Bool) -> Bool {
        false
    }

    func finish() {
        continuation?.resume(returning: true); continuation = nil
    }
}

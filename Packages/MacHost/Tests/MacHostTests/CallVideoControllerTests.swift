import ChatKit
import DesignSystem
import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
struct CallVideoControllerTests {
    @Test func selfPreviewCropFillsTheTileWhileWholeViewFitsIt() {
        let video = CGSize(width: 1600, height: 900)
        let tile = CGSize(width: 200, height: 200)
        #expect(CallVideoSurface.selfPreviewSize(video: video, container: tile, cropped: false) ==
            CGSize(width: 200, height: 112.5))
        let cropped = CallVideoSurface.selfPreviewSize(video: video, container: tile, cropped: true)
        #expect(abs(cropped.width - 355.5556) < 0.001)
        #expect(cropped.height == 200)
        #expect(CallVideoSurface.selfPreviewSize(video: .zero, container: tile, cropped: true) == tile)
    }

    @Test func receivePreferencesUseOnlyTheMediaRouteThatInstalledThem() {
        let controller = CallVideoController()
        let first = controller.install(CameraRoute())
        let old = NativeCallMedia(videoController: controller)
        old.videoScope = first
        let initial = CallVideoPreferences(personalPins: [UUID()], dismissedSharedPins: [UUID()])
        controller.setReceivePreferences(initial, ifCurrent: first)
        #expect((old as any CallMediaEngine).remoteVideoPreferences() == initial)

        let second = controller.install(CameraRoute())
        #expect((old as any CallMediaEngine).remoteVideoPreferences() == CallVideoPreferences())
        #expect(controller.receivePreferences(ifCurrent: second) == CallVideoPreferences())
        controller.setReceivePreferences(initial, ifCurrent: first)
        #expect(controller.receivePreferences(ifCurrent: second) == CallVideoPreferences())
        let current = CallVideoPreferences(personalPins: [UUID(), UUID()])
        controller.setReceivePreferences(current, ifCurrent: second)
        controller.clear(ifCurrent: first)
        #expect(controller.receivePreferences(ifCurrent: second) == current)
        controller.clear(ifCurrent: second)
        #expect(controller.receivePreferenceScope == nil)
        #expect(controller.receivePreferences(ifCurrent: second) == CallVideoPreferences())
    }

    @Test(arguments: [true, false])
    func aMeetingLockStopsTheCameraAndAnUnlockRequiresAnotherAction(duringStart: Bool) async {
        let controller = CallVideoController(), route = CameraRoute()
        let scope = controller.install(route)
        route.holdAnnouncement = duringStart
        controller.toggle()
        await wait { duringStart ? route.announcementContinuation != nil : controller.camera?.isOn == true }
        controller.setCameraAllowed(false, ifCurrent: scope)
        #expect(!route.sending)
        #expect(controller.camera?.allowsStart == false)
        if duringStart {
            route.finishAnnouncement()
        }
        await wait { controller.camera?.isUpdating == false }
        #expect(route.announcements == [true, false])
        #expect(route.stops == 1)
        controller.toggle()
        #expect(route.starts.count == 1)
        controller.setCameraAllowed(true, ifCurrent: scope)
        #expect(controller.camera?.isOn == false)
        controller.toggle()
        await wait { controller.camera?.isOn == true }
        #expect(route.starts.count == 2)
        controller.clear()
    }

    @Test func cameraStaysOffUntilExplicitActionAndSuccessfulAnnouncement() async {
        let controller = CallVideoController(), route = CameraRoute()
        controller.install(route)
        #expect(controller.camera?.isOn == false)
        #expect(route.starts.isEmpty)
        route.holdAnnouncement = true
        controller.toggle()
        await wait { route.announcements == [true] }
        #expect(route.sending == false)
        #expect(controller.camera?.isUpdating == true)
        route.finishAnnouncement()
        await wait { controller.camera?.isOn == true }
        #expect(route.sending)
        controller.toggle()
        #expect(!route.sending)
        #expect(controller.camera?.isOn == false)
        await wait { controller.camera?.isUpdating == false }
        #expect(route.announcements == [true, false])
        #expect(route.stops == 1)
        controller.clear()
    }

    @Test func failedPermissionOrProviderAcknowledgementNeverEnablesSending() async {
        for error in [CameraFailure.denied, .unavailable] {
            let controller = CallVideoController(), route = CameraRoute()
            route.startError = error
            controller.install(route)
            controller.toggle()
            await wait { controller.camera?.notice != nil }
            #expect(controller.camera?.isOn == false)
            #expect(!route.sending)
            #expect(route.announcements.isEmpty)
            controller.clear()
        }
        let controller = CallVideoController(), route = CameraRoute()
        route.announcementError = true
        controller.install(route)
        controller.toggle()
        await wait { controller.camera?.notice != nil }
        #expect(controller.camera?.isOn == false)
        #expect(!route.sending)
        #expect(route.stops == 1)
        controller.clear()
    }

    @Test func lateStartCannotEnableAfterClearOrReplaceNewCameraState() async {
        let controller = CallVideoController(), old = CameraRoute(), next = CameraRoute()
        old.holdStart = true
        let scope = controller.install(old)
        controller.toggle()
        await wait { old.starts.count == 1 }
        controller.clear(ifCurrent: scope)
        controller.install(next)
        old.finishStart()
        await wait { old.stops == 1 }
        #expect(old.announcements.isEmpty)
        #expect(!old.sending)
        #expect(controller.camera?.isUpdating == false)
        controller.showRemote(nil, visible: true, ifCurrent: scope)
        #expect(!controller.remoteVisible)
        controller.clear(ifCurrent: scope)
        #expect(controller.camera != nil)
        controller.setCameraAllowed(false, ifCurrent: scope)
        #expect(controller.camera?.allowsStart == true)
        controller.clear()
    }

    @Test func selectingCameraWhileOffDoesNotStartHardwareAndSwitchFailureTurnsVideoOff() async {
        let controller = CallVideoController(), route = CameraRoute()
        controller.install(route)
        controller.select("second")
        #expect(route.starts.isEmpty)
        controller.toggle()
        await wait { controller.camera?.isOn == true }
        #expect(route.starts == ["second"])
        route.startError = .unavailable
        controller.select("first")
        await wait { controller.camera?.notice != nil }
        #expect(!route.sending)
        #expect(controller.camera?.isOn == false)
        controller.clear()
    }

    @Test func turnOnOnlyEverTurnsTheCameraOn() async {
        let controller = CallVideoController(), route = CameraRoute()
        controller.turnOn()
        _ = controller.install(route)
        controller.select("second")
        controller.turnOn()
        await wait { controller.camera?.isOn == true }
        #expect(route.starts == ["second"])
        // Unlike `toggle`, a second call leaves it on.
        controller.turnOn()
        #expect(controller.camera?.isOn == true)
        #expect(route.sending)
        #expect(route.starts == ["second"])
        controller.clear()
    }

    @Test func theChosenCameraIsKeptForTheNextCall() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        let first = CallVideoController(preferences: place.preferences()), route = CameraRoute()
        first.install(route)
        #expect(first.camera?.selected == "")
        first.select("second")
        first.clear()
        #expect(place.preferences().camera == "second")

        let next = CallVideoController(preferences: place.preferences()), nextRoute = CameraRoute()
        next.install(nextRoute)
        #expect(next.camera?.selected == "second")
        // Kept, but never turned on by itself.
        #expect(nextRoute.starts.isEmpty)
        next.turnOn()
        await wait { next.camera?.isOn == true }
        #expect(nextRoute.starts == ["second"])
        next.clear()
    }

    @Test func aMissingSavedCameraUsesTheDefaultAndStaysSaved() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        place.preferences().saveCamera("unplugged")
        let controller = CallVideoController(preferences: place.preferences()), route = CameraRoute()
        controller.install(route)
        #expect(controller.camera?.selected == "")
        #expect(controller.camera?.notice == nil)
        controller.turnOn()
        await wait { controller.camera?.isOn == true }
        #expect(route.starts == [""])
        #expect(place.preferences().camera == "unplugged")
        controller.clear()
    }

    @Test func onlyAConfirmedPreJoinChoiceReachesTheInCallCameraRoute() async throws {
        let place = try DevicePreferencesPlace()
        defer { place.remove() }
        let route = CameraRoute()
        let preferences = place.preferences()
        preferences.saveCamera("unplugged")
        let preparation = CallPreparationDevices(
            preferences: preferences, readAudio: { .init() }, readCameras: { route.devices() }
        )
        let canceled = UUID()
        preparation.bind(canceled)
        #expect(preparation.camera == "first" && preparation.selectedCamera.isEmpty)
        preparation.selectCamera("second", for: canceled)
        #expect(preparation.camera == "second" && preferences.camera == "unplugged")
        preparation.bind(nil)
        preparation.saveChoices(for: canceled)
        #expect(preferences.camera == "unplugged")
        let joined = UUID()
        preparation.bind(joined)
        preparation.selectCamera("missing", for: joined)
        #expect(preparation.camera == "first")
        preparation.selectCamera("second", for: joined)
        preparation.saveChoices(for: joined)
        preparation.bind(nil)
        let controller = CallVideoController(preferences: preferences)
        _ = controller.install(route)
        #expect(controller.camera?.selected == "second" && route.starts.isEmpty)
        controller.turnOn()
        await wait { controller.camera?.isOn == true }
        #expect(route.starts == ["second"])
        controller.clear()
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        #expect(condition())
    }
}

@MainActor
final class CameraRoute: CallCameraRouting {
    var activeDevice = "first"
    var starts: [String] = []
    var announcements: [Bool] = []
    var sending = false
    var stops = 0
    var startError: CameraFailure?
    var announcementError = false
    var holdStart = false
    var holdAnnouncement = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var announcementContinuation: CheckedContinuation<Void, Never>?
    func devices() -> [CallCameraDevice] {
        [
            .init(id: "first", name: "Camera"),
            .init(id: "second", name: "Other camera")
        ]
    }

    func start(_ id: String) async throws {
        starts.append(id)
        if holdStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if let startError {
            throw startError
        }
        activeDevice = id.isEmpty ? "first" : id
    }

    func stop() async {
        stops += 1
    }

    func suppress() {
        sending = false
    }

    func send(_ enabled: Bool) {
        sending = enabled
    }

    func announce(_ enabled: Bool) async throws {
        announcements.append(enabled)
        if holdAnnouncement {
            await withCheckedContinuation { announcementContinuation = $0 }
        }
        if announcementError {
            throw CameraFailure.unavailable
        }
    }

    func finishStart() {
        startContinuation?.resume(); startContinuation = nil
    }

    func finishAnnouncement() {
        announcementContinuation?.resume(); announcementContinuation = nil; holdAnnouncement = false
    }
}

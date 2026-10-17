import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
struct CallVideoControllerTests {
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
private final class CameraRoute: CallCameraRouting {
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

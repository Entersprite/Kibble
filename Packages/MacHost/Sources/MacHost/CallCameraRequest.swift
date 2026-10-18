import AppCore
import ChatKit
import DesignSystem
import Foundation
import Observation

/// Turns the camera on, once, for a call started from the conversation's
/// Video Call button.
///
/// The camera arrives with the call's media and can be turned on at the
/// moments the call window's own camera button works: while the call rings or
/// is connected. The request waits for that, then asks once. It ends without
/// asking when the call finishes first, when the person has turned the camera
/// on themselves, or when the camera shows a problem, which then stays theirs
/// to read.
@MainActor
final class CallCameraRequest {
    enum Step: Equatable {
        case wait
        case turnOn
        case done
    }

    private var task: Task<Void, Never>?

    /// Replaces any earlier request, which belonged to an earlier call.
    func request(for id: UUID, calls: AudioCallController, video: CallVideoController) {
        task?.cancel()
        task = Task { [weak video] in
            let steps = Observations { @MainActor [weak video] in
                guard let video else { return Step.done }
                return Self.step(for: id, call: calls.call, isEnding: calls.isEnding, camera: video.camera)
            }
            for await step in steps {
                guard !Task.isCancelled else { return }
                switch step {
                case .wait:
                    continue
                case .turnOn:
                    video?.turnOn()
                    return
                case .done:
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    static func step(
        for id: UUID, call: AudioCallSnapshot?, isEnding: Bool, camera: CallCameraState?
    ) -> Step {
        guard let call, call.id == id, !call.phase.isTerminal, !isEnding else { return .done }
        guard call.phase == .connected || call.phase == .ringing, let camera else { return .wait }
        if camera.isOn || camera.notice != nil {
            return .done
        }
        return camera.isUpdating ? .wait : .turnOn
    }
}

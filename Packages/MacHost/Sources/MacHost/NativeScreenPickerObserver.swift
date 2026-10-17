import Foundation
@preconcurrency import ScreenCaptureKit

/// Keep the immutable filter on the main actor across continuation delivery.
@MainActor
final class NativeScreenSelection {
    let filter: SCContentFilter
    init(_ filter: SCContentFilter) {
        self.filter = filter
    }
}

/// A fresh observer per picker request binds queued callbacks to that request,
/// even if the system delivers them after cancellation and a new selection.
@MainActor
final class NativeScreenPickerObserver: NSObject, SCContentSharingPickerObserver {
    private let receive: (SCContentFilter?, Bool) -> Void
    private var finished = false

    init(receive: @escaping (SCContentFilter?, Bool) -> Void) {
        self.receive = receive
    }

    func cancel() {
        finished = true
    }

    private func complete(_ filter: SCContentFilter?, failed: Bool) {
        guard !finished else { return }
        finished = true
        receive(filter, failed)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let isNew = stream == nil
        Task { @MainActor [weak self] in
            guard isNew else { return }
            self?.complete(filter, failed: false)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        let isNew = stream == nil
        Task { @MainActor [weak self] in
            guard isNew else { return }
            self?.complete(nil, failed: false)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in self?.complete(nil, failed: true) }
    }
}

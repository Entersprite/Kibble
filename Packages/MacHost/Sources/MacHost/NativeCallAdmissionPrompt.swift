import AppKit
import LocalBridgeBackend

/// One cancellable notice sheet on the original account's own call window.
@MainActor
final class NativeCallAdmissionPrompt {
    typealias Presenter = @MainActor (
        NSAlert,
        NSWindow,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void
    private struct Pending {
        let id: UUID
        let alert: NSAlert
        let window: NSWindow
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: Pending?
    private let present: Presenter
    private let dismiss: @MainActor (NSAlert, NSWindow) -> Void

    init(
        present: @escaping Presenter = { alert, window, completion in
            alert.beginSheetModal(for: window, completionHandler: completion)
        },
        dismiss: @escaping @MainActor (NSAlert, NSWindow) -> Void = { alert, window in
            if alert.window.sheetParent === window {
                window.endSheet(alert.window, returnCode: .cancel)
            }
        }
    ) {
        self.present = present; self.dismiss = dismiss
    }

    func confirm(_ notices: [CallAdmissionNotice], in window: NSWindow) async -> Bool {
        guard !notices.isEmpty, pending == nil, window.attachedSheet == nil,
              !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let alert = Self.alert(for: notices)
                pending = Pending(id: id, alert: alert, window: window, continuation: continuation)
                present(alert, window) { [weak self] response in
                    self?.finish(id, accepted: response == .alertFirstButtonReturn)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, accepted: false) }
        }
    }

    func cancel() {
        if let pending {
            finish(pending.id, accepted: false)
        }
    }

    static func alert(for notices: [CallAdmissionNotice]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        // The question first, then what joining acknowledges, and a button
        // named for what it does.
        alert.messageText = "Join this meeting?"
        alert.informativeText = "This meeting uses:\n\n"
            + notices.map { "• " + $0.rawValue }.joined(separator: "\n")
            + "\n\nBy joining, you acknowledge this."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func finish(_ id: UUID, accepted: Bool) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        dismiss(pending.alert, pending.window)
        pending.continuation.resume(returning: accepted)
    }
}

import AppKit
import Foundation

public extension CallMenuModel {
    func copyNewMeetingLink() {
        guard !isCreatingMeetingLink, let calls = selectedMeetingLinkSource()?.calls,
              calls.canCreateMeetingLinks else { return }
        isCreatingMeetingLink = true
        Task {
            defer { isCreatingMeetingLink = false }
            do {
                let url = try await calls.createMeetingLink()
                guard selectedMeetingLinkSource()?.calls === calls else { return }
                let clipboard = NSPasteboard.general
                clipboard.clearContents()
                if !clipboard.writeObjects([url as NSURL]) {
                    showMeetingLinkError("The meeting was created, but the link could not be copied.")
                }
            } catch is CancellationError {
                return
            } catch {
                guard selectedMeetingLinkSource()?.calls === calls,
                      calls.canCreateMeetingLinks else { return }
                showMeetingLinkError("Meet did not return a link.")
            }
        }
    }

    func joinMeeting() {
        guard let source = meetingLinkSource(), source.calls.canJoinMeetingLinks else { return }
        let alert = NSAlert()
        alert.messageText = "Join a Meeting"
        alert.informativeText = "Paste the meeting link."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Meeting link"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), source.calls.meetingLinkHosts.contains(host),
              url.user == nil, url.password == nil, text.utf8.count <= 2048 else {
            let error = NSAlert()
            error.messageText = "Enter a valid meeting link"
            error.informativeText = "Paste an HTTPS link from a supported meeting service."
            error.runModal()
            return
        }
        guard meetingLinkSource()?.calls === source.calls else { return }
        source.calls.prepareMeeting(at: url)
    }

    private func showMeetingLinkError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t Copy a New Meeting Link"
        alert.informativeText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

import AppKit
import Foundation

public extension CallMenuModel {
    func joinMeeting() {
        guard let source = meetingLinkSource(), source.calls.canJoinMeetingLinks else { return }
        let alert = NSAlert()
        alert.messageText = "Join a Meeting"
        alert.informativeText = "Paste the meeting link."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Meeting link"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, text.utf8.count <= 2048 else {
            let error = NSAlert()
            error.messageText = "Enter a valid meeting link"
            error.informativeText = "The link must start with https://."
            error.runModal()
            return
        }
        source.calls.joinMeeting(at: url)
    }
}

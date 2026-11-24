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
        // A link that can't be joined brings the same prompt back with what
        // was typed and the reason, rather than a second alert that throws
        // the typing away.
        var typed = ""
        var problem: String?
        while true {
            let alert = Self.joinPrompt(typed: typed, problem: problem)
            guard alert.runModal() == .alertFirstButtonReturn,
                  let field = alert.accessoryView as? NSTextField else { return }
            typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = Self.meetingURL(from: typed, hosts: source.calls.meetingLinkHosts) {
                guard meetingLinkSource()?.calls === source.calls else { return }
                source.calls.prepareMeeting(at: url)
                return
            }
            problem = typed.isEmpty ? nil : Self.joinPromptProblem
        }
    }

    static let joinPromptProblem =
        "That isn’t a meeting link Kibble can join. Paste the whole link, starting with https://."

    static func joinPrompt(typed: String, problem: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Join a Meeting"
        alert.informativeText = problem ?? "Paste the meeting link. You can check your camera and "
            + "microphone before you join."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Meeting link"
        field.stringValue = typed
        field.setAccessibilityLabel("Meeting link")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert
    }

    /// An HTTPS link to one of the hosts the service joins, with no
    /// credentials in it and of a sane length; anything else is no link.
    static func meetingURL(from text: String, hosts: Set<String>) -> URL? {
        guard let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil, text.utf8.count <= 2048 else { return nil }
        return url
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

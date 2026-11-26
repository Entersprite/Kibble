import AppKit
import Testing
@testable import MacHost

/// Join Meeting…: which typed text is a link the service joins, and what the
/// prompt says when it comes back. No alert is shown; they are only built.
@MainActor
struct CallJoinMeetingPromptTests {
    private let hosts: Set = ["meet.example.test"]

    @Test func onlyAnHTTPSLinkToAJoinableHostIsAccepted() {
        let link = "https://meet.example.test/abc-defg-hij"
        #expect(CallMenuModel.meetingURL(from: link, hosts: hosts)?.absoluteString == link)
        #expect(CallMenuModel.meetingURL(from: "https://MEET.example.test/abc", hosts: hosts) != nil)
        #expect(CallMenuModel.meetingURL(from: "http://meet.example.test/abc", hosts: hosts) == nil)
        #expect(CallMenuModel.meetingURL(from: "https://other.example.test/abc", hosts: hosts) == nil)
        #expect(CallMenuModel.meetingURL(from: "https://user:pw@meet.example.test/abc", hosts: hosts) == nil)
        #expect(CallMenuModel.meetingURL(from: "abc-defg-hij", hosts: hosts) == nil)
        #expect(CallMenuModel.meetingURL(from: "", hosts: hosts) == nil)
        let long = link + String(repeating: "a", count: 2048)
        #expect(CallMenuModel.meetingURL(from: long, hosts: hosts) == nil)
    }

    @Test func aRefusedLinkComesBackWithTheTypingAndTheReason() throws {
        let first = CallMenuModel.joinPrompt(typed: "", problem: nil)
        #expect(first.buttons.map(\.title) == ["Continue", "Cancel"])
        #expect(first.informativeText.hasPrefix("Paste the meeting link."))
        let again = CallMenuModel.joinPrompt(typed: "not a link", problem: CallMenuModel.joinPromptProblem)
        let field = try #require(again.accessoryView as? NSTextField)
        #expect(field.stringValue == "not a link")
        #expect(again.informativeText == CallMenuModel.joinPromptProblem)
    }
}

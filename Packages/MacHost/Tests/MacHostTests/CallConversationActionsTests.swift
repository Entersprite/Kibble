import AppKit
import ChatKit
import Testing
@testable import MacHost

@MainActor
struct CallConversationActionsTests {
    @Test func copiedMeetingLinkSupportsURLAndPlainTextPaste() throws {
        let url = try #require(URL(string: "https://example.com/meeting/a?source=call"))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }

        #expect(clipboard.writeMeetingLink(url))
        #expect(clipboard.pasteboardItems?.count == 1)
        #expect(clipboard.string(forType: .string) == url.absoluteString)
        #expect(clipboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL == url)
    }

    @Test func continuousChatRequiresTheExactMeetingConversationInTheAccountDirectory() {
        let id = Conversation.ID("space/confirmed"), route = CallMeetingChat(
            conversationID: id,
            canSend: false
        )
        let unrelated = Conversation(id: .init("space/unrelated"), kind: .meetChat, title: "Daily")
        let differentKind = Conversation(id: id, kind: .space, title: "Daily")
        let confirmed = Conversation(id: id, kind: .meetChat, title: "Daily")
        #expect(MacAppDelegate.knownMeetingChat(route, in: []) == nil)
        #expect(MacAppDelegate.knownMeetingChat(route, in: [unrelated, differentKind]) == nil)
        #expect(MacAppDelegate.knownMeetingChat(route, in: [unrelated, confirmed]) == route)
        #expect(MacAppDelegate.knownMeetingChat(nil, in: [confirmed]) == nil)
    }
}

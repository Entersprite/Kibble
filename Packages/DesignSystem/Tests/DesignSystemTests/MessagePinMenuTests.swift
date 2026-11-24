import ChatKit
import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct MessagePinMenuTests {
    @Test func personalStarsAndSharedPinsOfferIndependentActions() {
        let message = Message(
            id: .init("message"), conversationID: .init("chat"), threadID: .init("thread"),
            sender: .init("other"), text: "Checklist", createdAt: Date(timeIntervalSince1970: 0)
        )
        var handlers = OwnMessageHandlers(pin: { _ in }, star: { _ in }, isStarred: { _ in true })
        let items = MessageMenuTable(own: handlers.items(for: message)).message.map(\.title)
        #expect(items == ["Unstar", "Pin for Everyone"])
        handlers.starIsPending = { _ in true }
        #expect(MessageMenuTable(own: handlers.items(for: message)).message
            .map(\.title) == ["Pin for Everyone"])
    }

    @Test func anyoneCanOfferSharedPinButUnconfirmedAndDeletedMessagesCannot() {
        var message = Message(
            id: .init("message"), conversationID: .init("chat"), threadID: .init("thread"),
            sender: .init("other"), text: "Shared checklist", createdAt: Date(timeIntervalSince1970: 0)
        )
        var calls = 0
        var handlers = OwnMessageHandlers(me: .init("me"), pin: { _ in calls += 1 })
        let own = handlers.items(for: message)
        let item = MessageMenuTable(own: own).message.first { $0.title == "Pin for Everyone" }
        #expect(item != nil)
        item?.run()
        #expect(calls == 1)
        handlers.isPinned = { _ in true }
        #expect(MessageMenuTable(own: handlers.items(for: message)).message.last?
            .title == "Unpin for Everyone")
        handlers.unconfirmed = [message.id]
        #expect(handlers.items(for: message) == nil)
        handlers.unconfirmed = []
        message.activity = .pinnedMessage
        #expect(handlers.items(for: message) == nil)
        message.activity = nil
        message.isDeleted = true
        #expect(handlers.items(for: message) == nil)
    }
}

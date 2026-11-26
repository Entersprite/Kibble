import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct MessageReferenceWiringTests {
    @Test func quotePreviewReachesTheOriginalAccountStoreAndRetiresWithTheScene() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        let source = Conversation(id: .init("source"), kind: .space)
        let author = Member(id: .init("author"), kind: .human, displayName: "Alex Example")
        let message = Message(
            id: .init("original"),
            conversationID: source.id,
            threadID: .init("thread"),
            sender: author.id,
            text: "Original text",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        services.backend.emit(.conversationsChanged([source]))
        services.backend.emit(.membersResolved([author]))
        #expect(await eventually { environment.sceneState.conversations.count == 1 })
        try services.store.apply([.upsertMessage(message), .upsertMembers([author])])
        let load = try #require(environment.actions.loadMessageReference)
        let address = MessageAddress(conversation: source.id, thread: message.threadID, message: message.id)
        let preview = await load(address)
        #expect(preview?.quote.text == "Original text")
        #expect(preview?.author?.displayName == "Alex Example")
        #expect(environment.sceneState.selected == nil)
        await environment.signOut()
        #expect(await load(address) == nil)
        #expect(environment.actions.loadMessageReference == nil)
    }

    @Test func aReferenceOpensThroughTheSceneAndRetiredSceneActionsCannotNavigate() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        #expect(environment.actions.openMessageReference == nil)
        await environment.start()
        let source = Conversation(id: .init("source"), kind: .space)
        let origin = Conversation(id: .init("origin"), kind: .space)
        services.backend.emit(.conversationsChanged([source, origin]))
        #expect(await eventually { environment.sceneState.conversations.count == 2 })
        let actions = environment.actions
        let open = try #require(actions.openMessageReference)
        actions.select(origin.id)
        open(MessageAddress(conversation: source.id))
        #expect(environment.sceneState.selected == source.id)
        let model = try #require(environment.runningModel)
        await environment.signOut()
        open(MessageAddress(conversation: origin.id))
        #expect(model.selected == source.id)
        #expect(environment.actions.openMessageReference == nil)
    }
}

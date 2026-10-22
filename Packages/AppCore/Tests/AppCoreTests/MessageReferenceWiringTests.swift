import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct MessageReferenceWiringTests {
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

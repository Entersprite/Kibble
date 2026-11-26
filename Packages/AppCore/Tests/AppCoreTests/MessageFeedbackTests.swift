import ChatKit
import Testing
@testable import AppCore

@MainActor
struct MessageFeedbackTests {
    @Test func onlyAnAdmittedComposerSendReachesTheHostFeedbackPort() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        let model = try #require(environment.runningModel)
        model.select(Conversation.ID("feedback-chat"))
        let actions = environment.actions
        actions.send(ComposedMessage(text: ""))
        #expect(services.messageFeedbackCount == 0)
        actions.send(ComposedMessage(text: "Local send feedback"))
        #expect(services.messageFeedbackCount == 1)
        await environment.signOut()
        #expect(model.didBeginSending == nil)
        actions.send(ComposedMessage(text: "Stale composer action"))
        #expect(services.messageFeedbackCount == 1)
    }
}

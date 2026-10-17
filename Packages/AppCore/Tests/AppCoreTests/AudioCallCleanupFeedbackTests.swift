import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct AudioCallCleanupFeedbackTests {
    @Test(arguments: [false, true])
    func cleanupNoticeSurvivesHangupWithoutResurrectingOldCalls(deliveredLate: Bool) async throws {
        let me = Member.ID("self")
        let peer = Member(id: .init("peer"), kind: .human)
        let conversation = Conversation(id: .init("opaque-dm"), kind: .directMessage, members: [me, peer.id])
        let service = RecordingAudioService(recipient: .init(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        ))
        let controller = AudioCallController()
        controller.start(service: service)
        #expect(await eventually { controller.canCall(conversation: conversation, members: [peer], me: me) })
        controller.startCall(in: conversation, members: [peer], me: me)
        let id = try #require(controller.call?.id)
        let notice = "Audio stopped locally; device leave is unconfirmed."
        if !deliveredLate {
            service.hangUpNotice = notice
        }
        controller.hangUp()
        #expect(await eventually { !controller.isEnding })
        var ended = try #require(controller.call)
        ended.failureMessage = notice
        if deliveredLate {
            service.emit(ended)
        }
        #expect(await eventually { controller.call?.failureMessage == notice })
        #expect(controller.call?.phase == .ended)
        controller.startCall(in: conversation, members: [peer], me: me)
        let replacement = try #require(controller.call?.id)
        #expect(replacement != id)
        service.emit(ended)
        #expect(controller.call?.id == replacement)
        #expect(controller.call?.failureMessage == nil)
        await controller.stop()
    }
}

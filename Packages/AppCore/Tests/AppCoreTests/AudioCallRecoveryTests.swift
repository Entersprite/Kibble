import ChatKit
import Foundation
import Observation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallRecoveryTests {
    private let recipient = AudioCallRecipient(
        conversationID: .init("opaque-dm"), memberID: .init("peer"), displayName: "Peer"
    )

    @Test func recoveryKeepsTheEventConsumerAndRestartsOnlyCalls() async {
        let calls = AudioCallController()
        let service = RecordingAudioService(recipient: recipient)
        calls.start(service: service)
        #expect(await eventually { service.listenCount == 1 })
        await calls.recover {
            #expect(calls.isRecovering)
            #expect(!calls.canRecover)
            #expect(service.stopCount == 1)
            return true
        }
        #expect(await eventually { service.listenCount == 2 })
        let incoming = service.snapshot(phase: .incoming, direction: .incoming)
        service.emit(incoming)
        #expect(await eventually { calls.call?.id == incoming.id })
        #expect(!calls.canRecover)
        await calls.recover { Issue.record("active calls cannot be interrupted"); return true }
        #expect(service.stopCount == 1)
        await calls.stop()
    }

    @Test func accountTeardownDuringRepairCannotRestartTheOldService() async {
        let calls = AudioCallController()
        let service = RecordingAudioService(recipient: recipient)
        calls.start(service: service)
        #expect(await eventually { service.listenCount == 1 })
        await calls.recover {
            await calls.stop()
            return true
        }
        #expect(!calls.isAvailable)
        #expect(!calls.isRecovering)
        #expect(service.listenCount == 1)
    }

    @Test func directoryProjectionAdmitsOnlyCurrentHumanPairsAndTracksChanges() async {
        let me = Member.ID("self")
        let peer = Member(id: recipient.memberID, kind: .human, displayName: "Peer")
        let dm = Conversation(id: recipient.conversationID, kind: .directMessage, members: [me, peer.id])
        let model = DirectoryModel()
        let service = RecordingAudioService(recipient: recipient)
        let calls = AudioCallController()
        calls.start(service: service, directory: {
            AudioCallRecipient.directory(
                conversations: model.conversations,
                members: model.members,
                me: model.me
            )
        })
        #expect(await eventually { service.directoryUpdates.last == [] })
        model.conversations = [dm]
        model.members = [peer.id: peer]
        model.me = me
        #expect(await eventually { service.directoryUpdates.last == [recipient] })
        var bot = peer
        bot.kind = .app
        model.members = [bot.id: bot]
        #expect(await eventually { service.directoryUpdates.last == [] })
        model.members = [peer.id: peer]
        #expect(await eventually { service.directoryUpdates.last == [recipient] })
        model.conversations = []
        #expect(await eventually { service.directoryUpdates.last == [] })
        await calls.stop()
    }
}

@MainActor
@Observable
private final class DirectoryModel {
    var conversations: [Conversation] = []
    var members: [Member.ID: Member] = [:]
    var me: Member.ID?
}

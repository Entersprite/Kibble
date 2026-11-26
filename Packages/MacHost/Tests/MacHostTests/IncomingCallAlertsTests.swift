import ChatKit
import Foundation
import Testing
import UserNotifications
@testable import MacHost

@MainActor
struct IncomingCallAlertsTests {
    private func incoming() -> AudioCallSession {
        AudioCallSession(AudioCallSnapshot(
            id: UUID(), recipient: AudioCallRecipient(
                conversationID: Conversation.ID("dm:alerts"), memberID: Member.ID("person:avery"),
                displayName: "Avery"
            ), direction: .incoming, phase: .incoming
        ))
    }

    @Test func callsRespectPauseDeliveryAndPreviewWithoutTreatingThemAsMessageMentions() {
        let call = incoming()
        var rule = ResolvedRule.builtIn
        rule.notifyAbout = .mentions
        #expect(IncomingCallAlert.make(call: call, rule: rule, paused: false)?.title == "Avery")
        rule.showsPreview = false
        #expect(IncomingCallAlert.make(call: call, rule: rule, paused: false)?.title == "Kibble")
        #expect(IncomingCallAlert.make(call: call, rule: rule, paused: true) == nil)
        #expect(IncomingCallAlert.make(call: call, rule: nil, paused: false) == nil)
        rule.delivery = .off
        #expect(IncomingCallAlert.make(call: call, rule: rule, paused: false) == nil)
    }

    @Test func onlyTheCurrentIncomingCallCanBeAnsweredOrDeclinedFromAnAlert() {
        let call = incoming()
        for response in [IncomingCallResponse.answer(call.id), .decline(call.id), .show(call.id)] {
            #expect(IncomingCallAlerts.isCurrent(response, call: call))
            #expect(!IncomingCallAlerts.isCurrent(response, call: nil))
            #expect(!IncomingCallAlerts.isCurrent(response, call: incoming()))
            for phase in [AudioCallPhase.connecting, .connected, .ended, .failed, .declined] {
                var updated = call
                updated.phase = phase
                #expect(!IncomingCallAlerts.isCurrent(response, call: updated))
            }
        }
    }

    @Test func notificationCategoriesPreserveMessagesAndRegisterExplicitCallActions() throws {
        let categories = UserNotificationDelivery.categories()
        let category = try #require(categories
            .first { $0.identifier == UserNotificationDelivery.callCategoryID })
        #expect(category.actions.map(\.identifier) == [
            UserNotificationDelivery.answerCallActionID, UserNotificationDelivery.declineCallActionID
        ])
        #expect(category.actions[0].options.contains(.foreground))
        #expect(!category.actions[1].options.contains(.foreground))
        let id = UUID()
        let info: [AnyHashable: Any] = [UserNotificationDelivery.callKey: id.uuidString]
        #expect(UserNotificationDelivery.callResponse(
            action: UserNotificationDelivery.answerCallActionID, userInfo: info
        ) == .answer(id))
        #expect(UserNotificationDelivery.callResponse(action: "unknown", userInfo: info) == nil)
        #expect(UserNotificationDelivery.callResponse(
            action: UserNotificationDelivery.answerCallActionID, userInfo: [:]
        ) == nil)
    }

    @Test func systemSoundAndPassiveDeliveryFollowTheResolvedRule() {
        let id = UUID()
        for delivery in [Delivery.bannerAndSound, .banner, .notificationCenter] {
            let content = UserNotificationDelivery.callContent(.init(
                id: id,
                title: "Avery",
                delivery: delivery
            ))
            #expect((content.sound != nil) == (delivery == .bannerAndSound))
            #expect((content.interruptionLevel == .passive) == (delivery == .notificationCenter))
            #expect(content.userInfo.count == 1)
            #expect(content.userInfo[UserNotificationDelivery.callKey] as? String == id.uuidString)
        }
    }

    @Test func duplicateSnapshotsDoNotReplayAndEndingWithdrawsTheAlert() async {
        var posted: [UUID] = []
        var withdrawn: [UUID] = []
        let alerts = IncomingCallAlerts(post: { posted.append($0.id) }, withdraw: { withdrawn.append($0) })
        let call = incoming()
        alerts.update(call: call, rule: .builtIn, paused: false)
        for _ in 0 ..< 200 where posted.isEmpty {
            await Task.yield()
        }
        #expect(posted == [call.id])
        alerts.update(call: call, rule: .builtIn, paused: false)
        var ended = call
        ended.phase = .ended
        alerts.update(call: ended, rule: .builtIn, paused: false)
        #expect(withdrawn == [call.id])
        alerts.update(call: call, rule: .builtIn, paused: false)
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(posted == [call.id])
    }

    @Test func answerOrSignOutWhilePostingRemovesTheLateSystemAlert() async throws {
        let gate = CallAlertGate()
        var withdrawn: [UUID] = []
        let alerts = IncomingCallAlerts(post: { _ in await gate.wait() }, withdraw: { withdrawn.append($0) })
        let call = incoming()
        alerts.update(call: call, rule: .builtIn, paused: false)
        for _ in 0 ..< 200 where gate.continuation == nil {
            await Task.yield()
        }
        try #require(gate.continuation != nil)
        alerts.update(call: nil, rule: nil, paused: true)
        #expect(withdrawn == [call.id])
        gate.continuation?.resume()
        for _ in 0 ..< 200 where withdrawn.count < 2 {
            await Task.yield()
        }
        #expect(withdrawn == [call.id, call.id])
    }
}

@MainActor
private final class CallAlertGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
}

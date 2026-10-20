import AppKit
import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
struct IncomingCallPanelTests {
    private func incoming() -> AudioCallSnapshot {
        AudioCallSnapshot(
            id: UUID(), recipient: AudioCallRecipient(
                conversationID: Conversation.ID("dm:panel"), memberID: Member.ID("person:avery"),
                displayName: "Avery"
            ), direction: .incoming, phase: .incoming
        )
    }

    private func rule(_ delivery: Delivery, preview: Bool = true) -> ResolvedRule {
        var rule = ResolvedRule.builtIn
        rule.delivery = delivery
        rule.showsPreview = preview
        return rule
    }

    private let panel = IncomingCallSurface(showsPanel: true, rings: true, focused: false)

    @Test func aBannerBecomesThePanelAndRingsOnlyWithSound() throws {
        let call = incoming()
        let person = Member(id: call.recipient.memberID, kind: .human, displayName: "Avery Stone")
        var surface = panel
        surface.person = person
        let loud = IncomingCallRoute.make(
            call: call,
            rule: rule(.bannerAndSound),
            paused: false,
            surface: surface
        )
        let content = try #require(loud.panel)
        #expect(content.name == "Avery")
        #expect(content.person == person)
        #expect(loud.rings)
        #expect(loud.notification == nil)
        #expect(!loud.raisesWindow)
        let quiet = IncomingCallRoute.make(call: call, rule: rule(.banner), paused: false, surface: surface)
        #expect(quiet.panel != nil)
        #expect(!quiet.rings)
        surface.rings = false
        #expect(!IncomingCallRoute.make(
            call: call,
            rule: rule(.bannerAndSound),
            paused: false,
            surface: surface
        )
        .rings)
    }

    @Test func aFailedAnswerShowsInThePanelThatStillRings() {
        var call = incoming()
        var surface = panel
        surface.endsOtherCall = true
        var shown: [IncomingCallPanelContent] = []
        let alerts = IncomingCallAlerts(post: { _ in }, withdraw: { _ in }, showPanel: { shown.append($0) })
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: surface)
        call.failureMessage = "Couldn’t end the other call."
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: surface)
        #expect(shown.map(\.problem) == [nil, "Couldn’t end the other call."])
        #expect(shown.allSatisfy { $0.endsOtherCall && $0.callID == call.id })
    }

    @Test func hiddenPreviewsHideTheCallerInThePanel() throws {
        var surface = panel
        surface.person = Member(id: Member.ID("person:avery"), kind: .human, displayName: "Avery")
        let route = IncomingCallRoute.make(
            call: incoming(), rule: rule(.bannerAndSound, preview: false), paused: false, surface: surface
        )
        let content = try #require(route.panel)
        #expect(content.name == nil)
        #expect(content.person == nil)
    }

    @Test func focusMirroringAndQuietRulesGetTheNotificationAloneWithoutRaisingTheWindow() {
        let call = incoming()
        var focused = panel
        focused.focused = true
        var mirrored = panel
        mirrored.mirrored = true
        for (surface, delivery) in [
            (focused, Delivery.bannerAndSound),
            (mirrored, .banner),
            (panel, .notificationCenter)
        ] {
            let route = IncomingCallRoute.make(
                call: call,
                rule: rule(delivery),
                paused: false,
                surface: surface
            )
            #expect(route.panel == nil)
            #expect(route.notification?.delivery == delivery)
            #expect(!route.raisesWindow)
        }
        // Focus that Kibble may not see is treated as no Focus.
        var unknown = panel
        unknown.focused = nil
        #expect(IncomingCallRoute.make(call: call, rule: rule(.banner), paused: false, surface: unknown)
            .panel != nil)
    }

    @Test func withThePanelOffABannerKeepsTodaysNotificationAndWindow() {
        let route = IncomingCallRoute.make(
            call: incoming(), rule: rule(.bannerAndSound), paused: false, surface: .notificationsOnly
        )
        #expect(route.panel == nil)
        #expect(route.notification != nil)
        #expect(route.raisesWindow)
    }

    @Test func pausedOffAndFinishedCallsGetNothing() {
        let call = incoming()
        #expect(IncomingCallRoute
            .make(call: call, rule: rule(.banner), paused: true, surface: panel) == .init())
        #expect(IncomingCallRoute
            .make(call: call, rule: rule(.off), paused: false, surface: panel) == .init())
        #expect(IncomingCallRoute.make(call: call, rule: nil, paused: false, surface: panel) == .init())
        var answered = call
        answered.phase = .connecting
        #expect(IncomingCallRoute
            .make(call: answered, rule: rule(.banner), paused: false, surface: panel) == .init())
    }

    @Test func thePanelShowsOnceRingsAndLeavesWhenTheCallIsAnswered() {
        let recorder = PanelRecorder()
        let alerts = recorder.alerts()
        var call = incoming()
        #expect(!alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: panel))
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: panel)
        #expect(recorder.shown.map(\.callID) == [call.id])
        #expect(recorder.rings == [true])
        #expect(recorder.posted.isEmpty)
        call.phase = .connecting
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: panel)
        #expect(recorder.hides == 1)
        #expect(recorder.rings == [true, false])
        #expect(recorder.posted.isEmpty)
    }

    @Test func aDismissedPanelStaysAwayForThatCallOnly() {
        let recorder = PanelRecorder()
        let alerts = recorder.alerts()
        let call = incoming()
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: panel)
        alerts.dismiss()
        #expect(recorder.hides == 1)
        #expect(recorder.rings == [true, false])
        alerts.update(call: call, rule: rule(.bannerAndSound), paused: false, surface: panel)
        #expect(recorder.shown.count == 1)
        let next = incoming()
        alerts.update(call: next, rule: rule(.bannerAndSound), paused: false, surface: panel)
        #expect(recorder.shown.map(\.callID) == [call.id, next.id])
    }

    @Test func aLatePhotoUpdatesThePanelInPlace() {
        let recorder = PanelRecorder()
        let alerts = recorder.alerts()
        let call = incoming()
        alerts.update(call: call, rule: rule(.banner), paused: false, surface: panel)
        var withPhoto = panel
        withPhoto.person = Member(
            id: call.recipient.memberID,
            kind: .human,
            displayName: "Avery",
            avatarURL: URL(string: "https://example.com/avery.png")
        )
        alerts.update(call: call, rule: rule(.banner), paused: false, surface: withPhoto)
        #expect(recorder.shown.count == 2)
        #expect(recorder.shown.last?.person?.avatarURL != nil)
        #expect(recorder.hides == 0)
        #expect(recorder.rings.isEmpty)
    }

    @Test func signOutHidesThePanelAndStopsTheRing() {
        let recorder = PanelRecorder()
        let alerts = recorder.alerts()
        alerts.update(call: incoming(), rule: rule(.bannerAndSound), paused: false, surface: panel)
        alerts.update(call: nil, rule: nil, paused: true)
        #expect(recorder.hides == 1)
        #expect(recorder.rings == [true, false])
    }

    @Test func thePanelWindowFloatsEverywhereWithoutTakingFocus() throws {
        let host = IncomingCallPanelHost(animates: false)
        let content = IncomingCallPanelContent(
            callID: UUID(), memberID: Member.ID("person:avery"), name: "Avery", person: nil
        )
        host.show(content, actions: .init(accept: {}, decline: {}, open: {}, dismiss: {}))
        defer { host.hide() }
        let panel = try #require(host.panel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.identifier == CallSurface.incomingPanel)
        #expect(panel.isVisible)
        #expect(panel.frame.size == IncomingCallPanelLayout.window)
        host.hide()
        #expect(!panel.isVisible)
    }

    @Test func thePanelSitsInTheTopRightCornerOfTheScreen() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let frame = IncomingCallPanelHost.frame(on: screen)
        let visible = screen.visibleFrame
        #expect(visible.contains(frame))
        // The glass is 12 points from the top and right edges.
        #expect(visible.maxX - (frame.maxX - IncomingCallPanelLayout.margin) == 12)
        #expect(visible.maxY - (frame.maxY - IncomingCallPanelLayout.margin) == 12)
    }

    @Test func callSettingsDefaultOnAndPersist() throws {
        let suite = "IncomingCallPanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FakeFocus()
        let model = CallSettingsModel(defaults: defaults, focusStatus: focus)
        #expect(model.state == CallSettingsState(
            showsPanel: true, rings: true, focus: .notDetermined, closesFinishedCalls: true
        ))
        model.setShowsPanel(false)
        model.setRings(false)
        model.setClosesFinishedCalls(false)
        let reloaded = CallSettingsModel(defaults: defaults, focusStatus: focus)
        #expect(!reloaded.showsPanel)
        #expect(!reloaded.rings)
        #expect(!reloaded.closesFinishedCalls)
        #expect(reloaded.isFocused == nil)
        focus.access = .allowed
        focus.focused = true
        reloaded.refreshFocusAccess()
        #expect(reloaded.focus == .allowed)
        #expect(reloaded.isFocused == true)
    }
}

@MainActor
private final class PanelRecorder {
    var shown: [IncomingCallPanelContent] = []
    var hides = 0
    var rings: [Bool] = []
    var posted: [UUID] = []

    func alerts() -> IncomingCallAlerts {
        IncomingCallAlerts(
            post: { [weak self] in self?.posted.append($0.id) }, withdraw: { _ in },
            showPanel: { [weak self] in self?.shown.append($0) },
            hidePanel: { [weak self] in self?.hides += 1 },
            ring: { [weak self] in self?.rings.append($0) }
        )
    }
}

@MainActor
private final class FakeFocus: FocusStatusReading {
    var access = CallFocusAccess.notDetermined
    var focused = false
    var isFocused: Bool? {
        access == .allowed ? focused : nil
    }

    func requestAccess() async -> CallFocusAccess {
        access
    }
}

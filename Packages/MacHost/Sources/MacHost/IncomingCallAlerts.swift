import ChatKit
import DesignSystem
import Foundation

enum IncomingCallResponse: Equatable, Sendable {
    case show(UUID, scope: UUID? = nil)
    case answer(UUID, scope: UUID? = nil)
    case decline(UUID, scope: UUID? = nil)

    var scope: UUID? {
        switch self {
        case let .show(_, scope), let .answer(_, scope), let .decline(_, scope): scope
        }
    }

    var callID: UUID {
        switch self {
        case let .show(id, _), let .answer(id, _), let .decline(id, _): id
        }
    }
}

struct IncomingCallAlert: Equatable, Sendable {
    let id: UUID
    let title: String
    let delivery: Delivery
    var scope: UUID?

    static func make(call: AudioCallSnapshot?, rule: ResolvedRule?, paused: Bool) -> Self? {
        guard let call, call.direction == .incoming, call.phase == .incoming,
              let rule, !paused, rule.delivery != .off else { return nil }
        guard [.bannerAndSound, .banner, .notificationCenter].contains(rule.delivery) else { return nil }
        return Self(
            id: call.id,
            title: rule.showsPreview ? call.recipient.displayName : "Kibble",
            delivery: rule.delivery
        )
    }
}

/// What this Mac allows beyond the conversation's rule. The default is the
/// behavior from before the panel: notifications only.
struct IncomingCallSurface: Equatable {
    var showsPanel = false
    var rings = true
    /// `nil` when Kibble may not see Focus, treated as no Focus.
    var focused: Bool?
    var mirrored = false
    /// The caller's directory entry, for the panel's photo.
    var person: Member?
    /// Another account's call holds the device, so answering ends it.
    var endsOtherCall = false

    static let notificationsOnly = Self()
}

/// How one incoming call reaches the person: the panel (and whether it
/// rings), the system notification, and whether the call window rises.
struct IncomingCallRoute: Equatable {
    var panel: IncomingCallPanelContent?
    var rings = false
    var notification: IncomingCallAlert?
    var raisesWindow = false

    /// The panel stands in for a banner. A known Focus, a mirrored display or
    /// a Notification Center-only rule get the notification alone, which macOS
    /// filters, and nothing that would pull the person to Kibble.
    static func make(
        call: AudioCallSnapshot?, rule: ResolvedRule?, paused: Bool, surface: IncomingCallSurface
    ) -> Self {
        guard let alert = IncomingCallAlert.make(call: call, rule: rule, paused: paused),
              let call, let rule else { return Self() }
        guard alert.delivery == .banner || alert.delivery == .bannerAndSound else {
            return Self(notification: alert)
        }
        guard surface.showsPanel else {
            return Self(notification: alert, raisesWindow: true)
        }
        guard surface.focused != true, !surface.mirrored else {
            return Self(notification: alert)
        }
        let content = IncomingCallPanelContent(
            callID: call.id, memberID: call.recipient.memberID,
            name: rule.showsPreview ? call.recipient.displayName : nil,
            person: rule.showsPreview ? surface.person : nil, endsOtherCall: surface.endsOtherCall
        )
        return Self(panel: content, rings: surface.rings && alert.delivery == .bannerAndSound)
    }
}

/// The call snapshot, rather than window lifetime, owns the alert. Late
/// delivery is removed even when posting finishes after answer or sign-out.
/// A call alerts once, by panel or by notification; the panel follows the
/// call until it is answered, declined, ended or dismissed.
@MainActor
final class IncomingCallAlerts {
    private let post: @MainActor (IncomingCallAlert) async -> Void
    private let withdraw: @MainActor (UUID) -> Void
    private let showPanel: @MainActor (IncomingCallPanelContent) -> Void
    private let hidePanel: @MainActor () -> Void
    private let ring: @MainActor (Bool) -> Void
    private var posting: Task<Void, Never>?
    private var current: IncomingCallAlert?
    private var panel: IncomingCallPanelContent?
    private var ringing = false
    private var observedCall: UUID?
    private var hasAlerted = false
    private var dismissed = false

    init(
        post: @escaping @MainActor (IncomingCallAlert) async -> Void,
        withdraw: @escaping @MainActor (UUID) -> Void,
        showPanel: @escaping @MainActor (IncomingCallPanelContent) -> Void = { _ in },
        hidePanel: @escaping @MainActor () -> Void = {},
        ring: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.post = post
        self.withdraw = withdraw
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.ring = ring
    }

    /// Returns whether the call window should rise for this call.
    @discardableResult
    func update(
        call: AudioCallSnapshot?, rule: ResolvedRule?, paused: Bool,
        surface: IncomingCallSurface = .notificationsOnly
    ) -> Bool {
        if observedCall != call?.id {
            observedCall = call?.id
            hasAlerted = false
            dismissed = false
        }
        let route = IncomingCallRoute.make(call: call, rule: rule, paused: paused, surface: surface)
        updatePanel(dismissed ? nil : route.panel, rings: route.rings)
        updateNotification(route.notification)
        return route.raisesWindow
    }

    /// The panel's ×: no panel and no ring for this call, without declining.
    func dismiss() {
        dismissed = true
        updatePanel(nil, rings: false)
    }

    private func updatePanel(_ next: IncomingCallPanelContent?, rings: Bool) {
        if let next, next.callID == panel?.callID || !hasAlerted {
            hasAlerted = true
            if next != panel {
                panel = next
                showPanel(next)
            }
            setRinging(rings)
        } else if panel != nil {
            panel = nil
            setRinging(false)
            hidePanel()
        }
    }

    private func setRinging(_ value: Bool) {
        guard value != ringing else { return }
        ringing = value
        ring(value)
    }

    private func updateNotification(_ next: IncomingCallAlert?) {
        guard current != next else { return }
        if let current {
            posting?.cancel()
            withdraw(current.id)
        }
        current = nil
        guard let next, !hasAlerted else { return }
        hasAlerted = true
        current = next
        let post = post
        let withdraw = withdraw
        posting = Task {
            guard !Task.isCancelled else { return }
            await post(next)
            if Task.isCancelled {
                withdraw(next.id)
            }
        }
    }

    static func isCurrent(_ response: IncomingCallResponse, call: AudioCallSnapshot?) -> Bool {
        call?.id == response.callID && call?.direction == .incoming && call?.phase == .incoming
    }
}

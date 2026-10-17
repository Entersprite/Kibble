import ChatKit
import Foundation

enum IncomingCallResponse: Equatable, Sendable {
    case show(UUID)
    case answer(UUID)
    case decline(UUID)

    var callID: UUID {
        switch self {
        case let .show(id), let .answer(id), let .decline(id): id
        }
    }
}

struct IncomingCallAlert: Equatable, Sendable {
    let id: UUID
    let title: String
    let delivery: Delivery

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

/// The call snapshot, rather than window lifetime, owns the alert. Late
/// delivery is removed even when posting finishes after answer or sign-out.
@MainActor
final class IncomingCallAlerts {
    private let post: @MainActor (IncomingCallAlert) async -> Void
    private let withdraw: @MainActor (UUID) -> Void
    private var posting: Task<Void, Never>?
    private var current: IncomingCallAlert?
    private var observedCall: UUID?
    private var hasAlerted = false

    init(
        post: @escaping @MainActor (IncomingCallAlert) async -> Void,
        withdraw: @escaping @MainActor (UUID) -> Void
    ) {
        self.post = post
        self.withdraw = withdraw
    }

    func update(call: AudioCallSnapshot?, rule: ResolvedRule?, paused: Bool) {
        if observedCall != call?.id {
            observedCall = call?.id
            hasAlerted = false
        }
        let next = IncomingCallAlert.make(call: call, rule: rule, paused: paused)
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

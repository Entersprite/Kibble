import ChatKit
import Foundation
import Observation

/// Whether a call is going on in the one conversation the person is looking
/// at, asked of the backend while it is on screen and again every
/// `interval`. Bounded on purpose: one conversation, one task, owned by the
/// call controller and stopped with it, never one poll per call card.
///
/// An answer is only as good as its age (`isActive(in:at:)`), measured from
/// when this client received it: the service asks the provider afresh for
/// each request, and the answer's own `checkedAt` is on the provider's clock,
/// which a client does not share (the fixture's runs on its world's dates).
/// A failed or missing answer is unknown, which is never the same as no call:
/// the header then offers what it offers without discovery, and never an
/// assured Join.
@MainActor
@Observable
public final class CallDiscoveryMonitor {
    /// What the monitor follows: the conversation on screen, if any, and
    /// whatever else should prompt a fresh look when it changes.
    struct Watch: Equatable {
        var conversation: Conversation.ID?
        /// This session's own call starting or ending changes who is in one.
        var inCall = false
        /// A new call entry in the transcript says something changed.
        var latestCallMessage: Message.ID?
    }

    /// The latest answer for the watched conversation; nil when there is
    /// none yet, the last ask failed, or the watch moved on.
    public private(set) var availability: ConversationCallAvailability?
    /// When `availability` arrived, on `now`'s clock.
    @ObservationIgnored private var receivedAt: Date?
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let maximumAge: TimeInterval
    @ObservationIgnored private let now: @MainActor () -> Date

    init(
        interval: Duration = .seconds(20), maximumAge: TimeInterval = 45,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.interval = interval
        self.maximumAge = maximumAge
        self.now = now
    }

    /// A call observed going on in `id` recently enough to offer Join. The
    /// clock is the one answers are received by, so `date` comes from it too
    /// when nil.
    public func isActive(in id: Conversation.ID, at date: Date? = nil) -> Bool {
        guard let availability, availability.conversationID == id,
              availability.status == .active, let receivedAt else { return false }
        let age = (date ?? now()).timeIntervalSince(receivedAt)
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    /// People the answer counted, when it counted any.
    public func participantCount(in id: Conversation.ID) -> Int? {
        guard let availability, availability.conversationID == id else { return nil }
        return availability.totalParticipants ?? availability.participants?.count
    }

    func start(
        watching watch: @escaping @MainActor () -> Watch,
        fetch: @escaping @MainActor (Conversation.ID) async throws -> ConversationCallAvailability?
    ) {
        stop()
        let scope = generation
        watching = Task { [weak self] in
            var previous: Watch?
            for await next in Observations(watch) {
                guard let self, !Task.isCancelled, generation == scope else { return }
                // Any conversation-list change reruns the watch; only a real
                // change of what it names asks again.
                guard next != previous else { continue }
                previous = next
                follow(next, fetch: fetch, scope: scope)
            }
        }
    }

    func stop() {
        generation += 1
        watching?.cancel()
        poll?.cancel()
        watching = nil
        poll = nil
        availability = nil
        receivedAt = nil
    }

    private func follow(
        _ watch: Watch,
        fetch: @escaping @MainActor (Conversation.ID) async throws -> ConversationCallAvailability?,
        scope: Int
    ) {
        poll?.cancel()
        poll = nil
        guard let id = watch.conversation else {
            availability = nil
            receivedAt = nil
            return
        }
        if availability?.conversationID != id {
            availability = nil
            receivedAt = nil
        }
        let interval = interval
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let answer: ConversationCallAvailability?
                do {
                    answer = try await fetch(id)
                } catch {
                    answer = nil
                }
                guard let self, !Task.isCancelled, generation == scope else { return }
                // An answer about another conversation is never shown for this one.
                receivedAt = now()
                availability = answer?.conversationID == id ? answer : nil
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}

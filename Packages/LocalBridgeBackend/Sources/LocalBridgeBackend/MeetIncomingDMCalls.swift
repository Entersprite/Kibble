import Foundation
import GChatBridgeCore

public struct IncomingMeetDMCall: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let person: UUID
}

/// Owner-started receiving trial. Only Accept resolves a DM; listening and
/// local dismissal never create media, devices or invitations.
public actor MeetIncomingDMCalls {
    public enum Event: Sendable {
        case status(String)
        case listening, listeningFailed
        case ring(IncomingMeetDMCall)
        case cleared
    }

    private struct Pending {
        let handle: IncomingMeetDMCall
        let ring: MeetPushWire.Ring
    }

    private let requests: PunctualRequests
    private let topic: PunctualTopic
    private let client: PunctualClient
    private let people: [String: UUID]
    private let validate: @Sendable () async throws -> Void
    private let prepare: @Sendable (UUID, MeetPushWire.Ring) async throws -> PreparedMeetDMCall
    private let decline: @Sendable (MeetPushWire.Ring) async throws -> Void
    private let discard: @Sendable (UUID) async -> Void
    private var watch: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var scope = UUID()
    private var pending: Pending?
    private var accepting: UUID?
    private var retired: [String] = []
    private var lines = ["Incoming DM watch: owner-operated; no automatic media or invitations"]
    private var receive: (@Sendable (Event) async -> Void)?

    init(
        requests: PunctualRequests, topic: PunctualTopic, client: PunctualClient, people: [String: UUID],
        validate: @escaping @Sendable () async throws -> Void,
        prepare: @escaping @Sendable (UUID, MeetPushWire.Ring) async throws -> PreparedMeetDMCall,
        decline: @escaping @Sendable (MeetPushWire.Ring) async throws -> Void = { _ in
            throw MeetDMCallTrialError.callNotPrepared
        },
        discard: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.requests = requests
        self.topic = topic
        self.client = client
        self.people = people
        self.validate = validate
        self.prepare = prepare
        self.discard = discard
        self.decline = decline
    }

    var offeredCall: IncomingMeetDMCall? {
        pending?.handle
    }

    public var report: String {
        lines.joined(separator: "\n")
    }

    public func run(receive: @escaping @Sendable (Event) async -> Void) async {
        guard watch == nil else { return }
        scope = UUID()
        let current = scope
        self.receive = receive
        record("Meet watch: starting")
        await receive(.status("Connecting to incoming calls…"))
        guard scope == current else { return }
        let task = Task { [requests, topic, client, validate] in
            await MeetIncomingWatch
                .run(requests: requests, topic: topic, client: client, validate: validate) {
                    await self.handle($0, scope: current)
                }
        }
        watch = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard scope == current else { return }
        watch = nil
        expiry?.cancel()
        pending = nil
        accepting = nil
        await receive(.cleared)
    }

    public func stop() async {
        scope = UUID()
        watch?.cancel()
        watch = nil
        expiry?.cancel()
        expiry = nil
        if let pending {
            retire(pending.ring.id)
        }
        pending = nil
        accepting = nil
        record("Meet watch: stopped locally")
        await receive?(.cleared)
        await receive?(.status("Incoming call listening stopped."))
    }

    public func dismiss(_ handle: UUID) async {
        guard let pending, pending.handle.id == handle, accepting == nil else { return }
        retire(pending.ring.id)
        self.pending = nil
        expiry?.cancel()
        record("Incoming call: dismissed locally; no Decline RPC sent")
        await receive?(.cleared)
    }

    public func decline(_ handle: UUID) async throws {
        guard let offered = pending, offered.handle.id == handle, accepting == nil else {
            throw MeetDMCallTrialError.callNotPrepared
        }
        let current = scope
        accepting = handle
        defer {
            if accepting == handle {
                accepting = nil
            }
        }
        try await validate()
        try Task.checkCancellation()
        guard scope == current, pending?.handle.id == handle else { throw MeetDMCallTrialError.superseded }
        // Consume before the mutation. An ambiguous failure must not permit a
        // repeated click to send the same decline twice.
        retire(offered.ring.id)
        pending = nil
        expiry?.cancel()
        await receive?(.cleared)
        guard scope == current else { throw MeetDMCallTrialError.superseded }
        do {
            try await decline(offered.ring)
            try await validate()
            guard scope == current else { throw MeetDMCallTrialError.superseded }
            record("DeclineMeetingInvite: accepted")
            record("Incoming decline: sent; caller ringing termination is not confirmed")
        } catch {
            record("DeclineMeetingInvite: unconfirmed; " + MeetDMCallTrial.errorDescription(error))
            throw error
        }
    }

    public func accept(_ handle: UUID) async throws -> PreparedMeetDMCall {
        guard let offered = pending, offered.handle.id == handle, accepting == nil else {
            throw MeetDMCallTrialError.callNotPrepared
        }
        let current = scope
        accepting = handle
        defer {
            if accepting == handle {
                accepting = nil
            }
        }
        record("Incoming call: owner requested native acceptance")
        do {
            return try await prepareAccepted(offered, scope: current)
        } catch {
            record("Incoming accept: " + MeetDMCallTrial.errorDescription(error))
            throw error
        }
    }

    private func prepareAccepted(_ offered: Pending, scope current: UUID) async throws -> PreparedMeetDMCall {
        let handle = offered.handle.id
        try await validate()
        guard scope == current, pending?.handle.id == handle else { throw MeetDMCallTrialError.superseded }
        let ticket = try await prepare(offered.handle.person, offered.ring)
        do {
            try await validate()
            try Task.checkCancellation()
            guard scope == current,
                  pending?.handle.id == handle else { throw MeetDMCallTrialError.superseded }
            retire(offered.ring.id)
            pending = nil
            expiry?.cancel()
            record("Incoming call: owner accepted; prepared the matching DM")
            await receive?(.cleared)
            guard scope == current else { throw MeetDMCallTrialError.superseded }
            return ticket
        } catch {
            await discard(ticket.id)
            throw error
        }
    }

    func handle(_ event: MeetIncomingWatch.Event, scope current: UUID? = nil) async {
        guard current == nil || scope == current else { return }
        switch event {
        case .opened:
            record("Meet watch: opened")
            await receive?(.status("Meet watch opened; waiting for subscription…"))
        case let .diagnostic(message): record(message)
        case let .failed(message):
            record(message)
            await receive?(.status(message))
            await receive?(.listeningFailed)
        case .notification(.started):
            record("Meet watch: subscription started")
            await receive?(.status("Listening for calls from loaded human DMs."))
            await receive?(.listening)
        case let .notification(.ring(ring)): await offer(ring)
        case let .notification(.ended(id, reason)):
            retire(id)
            record("Meet watch: ring ended; reason \(reason.map(String.init) ?? "absent")")
            guard pending?.ring.id == id else { return }
            pending = nil
            expiry?.cancel()
            await receive?(.cleared)
        case .notification(.stopped): break // The transport reports subscription failures.
        }
    }

    private func offer(_ ring: MeetPushWire.Ring) async {
        guard !retired.contains(ring.id), pending?.ring.id != ring.id else { return }
        let dmID = ring.dmID.hasPrefix("dm/") ? String(ring.dmID.dropFirst(3)) : ring.dmID
        guard let person = people[dmID] else {
            retire(ring.id)
            record("Meet watch: ring ignored; no loaded human DM matches")
            return
        }
        guard pending == nil, accepting == nil else {
            retire(ring.id)
            record("Meet watch: additional ring ignored while a call is pending")
            return
        }
        let handle = IncomingMeetDMCall(id: UUID(), person: person)
        pending = Pending(handle: handle, ring: ring)
        record("Meet watch: matched one loaded human DM; call kind \(ring.kind)")
        expiry?.cancel()
        expiry = Task {
            do { try await Task.sleep(for: .seconds(36)) } catch { return }
            await self.expire(handle.id)
        }
        await receive?(.ring(handle))
    }

    func expire(_ handle: UUID) async {
        guard let pending, pending.handle.id == handle else { return }
        retire(pending.ring.id)
        self.pending = nil
        record("Incoming call: local ringing timeout")
        await receive?(.cleared)
    }

    private func retire(_ id: String) {
        guard !retired.contains(id) else { return }
        retired.append(id)
        if retired.count > 256 {
            retired.removeFirst(retired.count - 256)
        }
    }

    private func record(_ line: String) {
        lines.append(line)
        if lines.count > 256 {
            lines.removeFirst(lines.count - 256)
        }
    }
}

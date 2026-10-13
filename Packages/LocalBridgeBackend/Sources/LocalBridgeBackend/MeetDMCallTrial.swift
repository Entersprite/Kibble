import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

public struct MeetDMCallPerson: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let email: String?
}

public struct PreparedMeetDMCall: Sendable {
    public let id: UUID
    public let url: URL
}

public enum MeetDMCallTrialError: Error, Sendable, Equatable {
    case noSession, signedOut, missingSelf, accountChanged, invalidPerson, callNotPrepared, superseded
    case browserJoinRequired, callChanged
}

public enum MeetDMCallLoadStep: String, Sendable {
    case storedSession = "Reading the saved Chat session…"
    case chatBootstrap = "Connecting to Chat…"
    case selfAccount = "Checking your Chat account…"
    case conversations = "Loading your DM conversations…"
    case profiles = "Loading people's names…"
    case ready = "Checking the loaded people list…"
}

/// An owner-operated trial: loading people sends only Chat queries; preparing
/// resolves a DM; only `ring` sends an invitation. Provider IDs and tokens stay
/// in this actor. Public UUIDs are temporary handles, not Google identifiers.
public actor MeetDMCallTrial {
    private struct Target {
        let dmID: String
        let calleeID: String
    }

    private struct Context {
        let stored: StoredSession
        let credentials: SessionCredentials
    }

    private struct Prepared {
        let ticket: UUID
        let generation: Int
        let target: Target
        let context: Context
        let client: MeetCallClient
        let call: MeetResolvedCall
        let ownerReportedBrowserJoin: Bool
    }

    private let store: KeychainCredentialStore
    private let transport: any HTTPTransport
    private let endpoints: ChatEndpoints
    private var targets: [UUID: Target] = [:]
    private var context: Context?
    private var prepared: Prepared?
    private var native: NativeMeetCallSession?
    private var generation = 0
    private var lines = [
        "kibble native DM call trial",
        "Native audio/device trial; invitations are explicit and require a connected joined device.", ""
    ]

    public init(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints()
    ) {
        self.store = store
        self.transport = transport
        self.endpoints = endpoints
    }

    public var report: String {
        lines.joined(separator: "\n")
    }

    public func loadPeople(
        progress: @Sendable (MeetDMCallLoadStep) async -> Void = { _ in }
    ) async throws -> [MeetDMCallPerson] {
        await close()
        let currentGeneration = generation
        do {
            lines.append("Load people: started")
            try await loadProgress(.storedSession, generation: currentGeneration, progress: progress)
            guard let stored = try await store.currentSession() else { throw MeetDMCallTrialError.noSession }
            lines.append("Stored Chat session: present")
            try await loadProgress(.chatBootstrap, generation: currentGeneration, progress: progress)
            let wiz = try await Bootstrap(transport: transport).run(
                cookies: stored.credential,
                endpoints: endpoints
            )
            guard wiz.isSignedIn else { throw MeetDMCallTrialError.signedOut }
            lines.append("Chat bootstrap: accepted")
            let credentials = SessionCredentials(stored.credential, onRotation: { [store] rotated in
                try? await store.replaceCredential(with: rotated, belongingTo: stored)
            })
            let chat = ProtoAPIClient(
                transport: transport, endpoints: endpoints, credentials: credentials, xsrfToken: wiz.xsrfToken
            )
            try await loadProgress(.selfAccount, generation: currentGeneration, progress: progress)
            let selfStatus = try await chat.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            let selfID = selfStatus.userStatus.userID.id
            guard !selfID.isEmpty else { throw MeetDMCallTrialError.missingSelf }
            lines.append("get_self_user_status: accepted")
            try await loadProgress(.conversations, generation: currentGeneration, progress: progress)
            let world = try await chat.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            let mapped = WorldMapping.map(world)
            lines.append(
                "paginated_world: accepted; \(world.worldItems.count) items; "
                    + "\(mapped.conversations.count) visible conversations; \(mapped.skipped) unmapped"
            )
            let candidates = Self.candidates(mapped.conversations, selfID: selfID)
            lines.append(contentsOf: candidates.diagnostics)
            try await loadProgress(.profiles, generation: currentGeneration, progress: progress)
            let people = try await namedPeople(candidates.targets, using: chat)
            try await loadProgress(.ready, generation: currentGeneration, progress: progress)
            try await ensureCurrent(stored)
            try ensureGeneration(currentGeneration)
            context = Context(stored: stored, credentials: credentials)
            targets = people.targets
            lines.append("Loaded \(people.people.count) named human DM recipients.")
            return people.people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            lines.append("Load people: \(Self.errorDescription(error))")
            throw error
        }
    }

    public func prepare(person: UUID) async throws -> PreparedMeetDMCall {
        await endNativeCall()
        prepared = nil
        generation += 1
        let currentGeneration = generation
        do {
            guard let target = targets[person], let context else { throw MeetDMCallTrialError.invalidPerson }
            try await ensureCurrent(context.stored)
            let accountIndex = switch endpoints.account {
            case let .index(index): index
            case .none: 0
            }
            let configuration = try await MeetCallBootstrap(
                transport: transport, credentials: context.credentials
            ).loadConfiguration(accountIndex: accountIndex, userAgent: endpoints.userAgent)
            lines.append("Meet call shell: client key found")
            lines.append("Meet RTC client header: validated client descriptor protobuf")
            try ensureGeneration(currentGeneration)
            let client = MeetCallClient(
                transport: transport, credentials: context.credentials, configuration: configuration,
                sha1: SHA1.hex
            )
            let call = try await client.resolve(dmID: target.dmID)
            try await ensureCurrent(context.stored)
            try ensureGeneration(currentGeneration)
            let ticket = UUID()
            prepared = Prepared(
                ticket: ticket, generation: currentGeneration, target: target,
                context: context, client: client, call: call, ownerReportedBrowserJoin: false
            )
            lines.append("ResolveForHangoutsChat: accepted; valid normal Meet URL (value withheld)")
            return PreparedMeetDMCall(id: ticket, url: call.space.url)
        } catch {
            lines.append("Prepare: \(Self.errorDescription(error))")
            throw error
        }
    }

    /// The owner confirms being joined in the browser. Resolve again for this
    /// same DM and space before allowing a native invite. A browser device's
    /// token is never imported; whether this refreshed token suffices is a
    /// separate protocol check. This method cannot send an invitation.
    public func prepareRingAfterBrowserJoin(preparedID: UUID) async throws -> PreparedMeetDMCall {
        guard let previous = prepared, previous.ticket == preparedID else {
            throw MeetDMCallTrialError.callNotPrepared
        }
        prepared = nil
        generation += 1
        let currentGeneration = generation
        do {
            lines.append("Owner reported joining the prepared call in the browser")
            try await ensureCurrent(previous.context.stored)
            try ensureGeneration(currentGeneration)
            let call = try await previous.client.resolve(dmID: previous.target.dmID)
            try await ensureCurrent(previous.context.stored)
            try ensureGeneration(currentGeneration)
            guard call.space == previous.call.space else { throw MeetDMCallTrialError.callChanged }
            let ticket = UUID()
            prepared = Prepared(
                ticket: ticket, generation: currentGeneration, target: previous.target,
                context: previous.context, client: previous.client, call: call, ownerReportedBrowserJoin: true
            )
            lines.append("Resolve after browser join: accepted; same Meet space; new response token retained")
            return PreparedMeetDMCall(id: ticket, url: call.space.url)
        } catch {
            lines.append("Resolve after browser join: \(Self.errorDescription(error))")
            throw error
        }
    }

    public func ring(preparedID: UUID) async throws {
        guard let call = prepared,
              call.ticket == preparedID else { throw MeetDMCallTrialError.callNotPrepared }
        guard call.ownerReportedBrowserJoin || native != nil else {
            throw MeetDMCallTrialError.browserJoinRequired
        }
        // Consume before suspending. A repeated click or ambiguous transport
        // failure cannot automatically send a second invitation.
        prepared = nil
        do {
            try await ensureCurrent(call.context.stored)
            try ensureGeneration(call.generation)
            if let native {
                try await native.invite(callee: call.target.calleeID)
                await lines.append(contentsOf: native.takeReport())
                return
            }
            try await call.client.invite(call.call, calleeID: call.target.calleeID, requestID: UUID())
            lines
                .append(
                    "CreateMeetingInvite: accepted after reported browser join (Kibble created no device)"
                )
        } catch {
            lines.append("CreateMeetingInvite: \(Self.errorDescription(error))")
            throw error
        }
    }

    public func close() async {
        generation += 1
        targets = [:]
        context = nil
        prepared = nil
        await endNativeCall()
    }

    public func joinNative(preparedID: UUID, media: any CallMediaEngine) async throws {
        guard let call = prepared, call.ticket == preparedID, native == nil else {
            throw MeetDMCallTrialError.callNotPrepared
        }
        let session = NativeMeetCallSession(
            client: call.client, call: call.call, media: media,
            validateAccount: { [weak self] in
                guard let self else { throw MeetDMCallTrialError.superseded }
                try await validateNative(call.context.stored, generation: call.generation)
            }
        )
        native = session
        do {
            try await session.connect()
            await lines.append(contentsOf: session.takeReport())
        } catch {
            await lines.append(contentsOf: session.takeReport())
            if prepared?.ticket == call.ticket {
                prepared = nil
            }
            throw error
        }
    }

    public func endNativeCall() async {
        guard let session = native else { return }
        native = nil
        await session.close()
        await lines.append(contentsOf: session.takeReport())
    }

    private func validateNative(_ stored: StoredSession, generation: Int) async throws {
        try await ensureCurrent(stored)
        try ensureGeneration(generation)
    }

    private func ensureCurrent(_ expected: StoredSession) async throws {
        guard let stored = try await store.currentSession(),
              stored.capturedAt == expected.capturedAt, stored.expiresAt == expected.expiresAt
        else { throw MeetDMCallTrialError.accountChanged }
    }

    private func ensureGeneration(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw MeetDMCallTrialError.superseded }
    }

    private func loadProgress(
        _ step: MeetDMCallLoadStep, generation: Int,
        progress: @Sendable (MeetDMCallLoadStep) async -> Void
    ) async throws {
        try ensureGeneration(generation)
        lines.append("Loading step: \(step.rawValue)")
        await progress(step)
        try ensureGeneration(generation)
    }
}

private extension MeetDMCallTrial {
    private static func candidates(
        _ conversations: [Conversation], selfID: String
    ) -> (targets: [Target], diagnostics: [String]) {
        var seen = Set<String>()
        var direct = 0
        var pairs = 0
        var ownerPairs = 0
        var differingEstimates = 0
        let targets: [Target] = conversations.compactMap { conversation in
            guard let dmID = MeetCallProbeReport.dmID(for: conversation) else { return nil }
            direct += 1
            let members = Set(conversation.members.map(\.rawValue))
            guard members.count == 2 else { return nil }
            pairs += 1
            guard members.contains(selfID) else { return nil }
            ownerPairs += 1
            // The segmented count is an estimate. The DM kind and actual
            // owner/peer pair establish the recipient; a different estimate
            // is diagnostic information, not grounds to discard that person.
            if let count = conversation.memberCount, count != 2 {
                differingEstimates += 1
            }
            guard
                let callee = members.first(where: { $0 != selfID }), seen.insert(callee).inserted
            else { return nil }
            return Target(dmID: dmID, calleeID: callee)
        }
        return (targets, [
            "Human DM filters: \(direct) human DMs; \(pairs) with two listed members; "
                + "\(ownerPairs) including current account; "
                + "\(differingEstimates) with differing count estimates; "
                + "\(targets.count) unique recipients"
        ])
    }

    private func namedPeople(
        _ candidates: [Target], using chat: ProtoAPIClient
    ) async throws -> (people: [MeetDMCallPerson], targets: [UUID: Target]) {
        guard !candidates.isEmpty else {
            lines.append("get_members: not sent; no candidate recipients")
            return ([], [:])
        }
        let response = try await chat.call(
            .getMembers, LocalBridgeBackend.getMembersRequest(candidates.map { .init($0.calleeID) })
        )
        let mapped = MemberMapping.map(response)
        lines.append(
            "get_members: accepted; \(response.members.count) profiles; "
                + "\(mapped.members.count) mapped; \(mapped.skipped) unmapped"
        )
        let members = Dictionary(
            mapped.members.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var people: [MeetDMCallPerson] = []
        var selected: [UUID: Target] = [:]
        var matching = 0
        var human = 0
        for target in candidates {
            guard let member = members[target.calleeID] else { continue }
            matching += 1
            guard member.kind == .human else { continue }
            human += 1
            guard let name = member.displayName ?? member.email, !name.isEmpty
            else { continue }
            let id = UUID()
            people.append(MeetDMCallPerson(id: id, name: name, email: member.email))
            selected[id] = target
        }
        lines.append(
            "Recipient profiles: \(matching) matched; \(human) human; \(people.count) named"
        )
        return (people, selected)
    }
}

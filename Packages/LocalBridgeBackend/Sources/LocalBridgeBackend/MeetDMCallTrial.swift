import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// Owner-operated DM trial. Only explicit ring sends invitations; provider
/// IDs/tokens stay in this actor and public UUIDs are temporary handles.
public actor MeetDMCallTrial {
    struct Target: Sendable {
        let dmID: String
        let calleeID: String
    }

    private struct Context {
        let stored: StoredSession
        let credentials: SessionCredentials
        let push: MeetPushConfiguration?
        let pushDiagnostics: [String]
    }

    private struct Prepared {
        let ticket: UUID
        let generation: Int
        let target: Target
        let context: Context
        let client: MeetCallClient
        let call: MeetResolvedCall
        let ownerReportedBrowserJoin: Bool
        let permitsInvitation: Bool
    }

    private let store: KeychainCredentialStore
    private let transport: any HTTPTransport
    private let endpoints: ChatEndpoints
    private var targets: [UUID: Target] = [:]
    private var context: Context?
    private var prepared: Prepared?
    private var native: NativeMeetCallSession?
    private var generation = 0
    var lines = [
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
            context = Context(
                stored: stored, credentials: credentials, push: wiz.meetPushConfiguration,
                pushDiagnostics: wiz.meetPushDiagnostics
            )
            targets = people.targets
            lines.append("Loaded \(people.people.count) named human DM recipients.")
            return people.people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            lines.append("Load people: \(Self.errorDescription(error))")
            throw error
        }
    }

    private var watchScope = UUID()

    public func prepare(person: UUID) async throws -> PreparedMeetDMCall {
        await endNativeCall()
        prepared = nil
        generation += 1
        let currentGeneration = generation
        do {
            guard let target = targets[person], let context else { throw MeetDMCallTrialError.invalidPerson }
            try await ensureCurrent(context.stored)
            let client = try await loadCallClient(context, generation: currentGeneration)
            let call = try await client.resolve(dmID: target.dmID)
            try await ensureCurrent(context.stored)
            try ensureGeneration(currentGeneration)
            let ticket = UUID()
            prepared = Prepared(
                ticket: ticket, generation: currentGeneration, target: target,
                context: context, client: client, call: call, ownerReportedBrowserJoin: false,
                permitsInvitation: true
            )
            lines.append("ResolveForHangoutsChat: accepted; valid normal Meet URL (value withheld)")
            return PreparedMeetDMCall(id: ticket, url: call.space.url)
        } catch {
            lines.append("Prepare: \(Self.errorDescription(error))")
            throw error
        }
    }

    /// Legacy browser confirmation trial: refreshes the same DM/space but
    /// creates no device and imports no browser credentials. Incoming calls
    /// cannot enter this invitation path.
    public func prepareRingAfterBrowserJoin(preparedID: UUID) async throws -> PreparedMeetDMCall {
        guard let previous = prepared, previous.ticket == preparedID, previous.permitsInvitation else {
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
                context: previous.context, client: previous.client, call: call,
                ownerReportedBrowserJoin: true,
                permitsInvitation: true
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
              call.ticket == preparedID,
              call.permitsInvitation else { throw MeetDMCallTrialError.callNotPrepared }
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
        watchScope = UUID()
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

extension MeetDMCallTrial {
    public func incomingCalls() async throws -> MeetIncomingDMCalls {
        guard let context else { throw MeetDMCallTrialError.noSession }
        let currentGeneration = generation
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let push = try await pushConfiguration(context, generation: currentGeneration)
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let scope = UUID()
        watchScope = scope
        let people = Dictionary(uniqueKeysWithValues: targets.map { ($0.value.dmID, $0.key) })
        let client = PunctualClient(
            transport: transport,
            credentials: context.credentials,
            authorization: { jar, url in
                SAPISIDHash.browserAuthorization(for: .init(
                    cookies: jar.cookies, url: url, origin: "https://chat.google.com",
                    timestamp: Int(Date().timeIntervalSince1970)
                ), sha1: SHA1.hex)
            }
        )
        return MeetIncomingDMCalls(
            requests: PunctualRequests(meet: push, endpoints: endpoints), topic: .meetRings(push),
            client: client,
            people: people,
            validate: { [weak self] in
                guard let self else { throw MeetDMCallTrialError.superseded }
                try await validateWatch(context.stored, scope: scope)
            },
            prepare: { [weak self] person, ring in
                guard let self else { throw MeetDMCallTrialError.superseded }
                return try await prepareIncoming(person: person, ring: ring)
            },
            discard: { [weak self] ticket in await self?.discardIncoming(ticket) }
        )
    }

    private func pushConfiguration(
        _ context: Context,
        generation: Int
    ) async throws -> MeetPushConfiguration {
        lines.append("Incoming watch config: initial Chat shell")
        lines.append(contentsOf: context.pushDiagnostics)
        if let push = context.push {
            return push
        }
        lines.append("Incoming watch config: reading standalone Chat page…")
        do {
            let wiz = try await MeetPushBootstrap(transport: transport, credentials: context.credentials)
                .load(endpoints: endpoints)
            try await ensureCurrent(context.stored)
            try ensureGeneration(generation)
            lines.append("Incoming watch config: standalone Chat shell accepted")
            lines.append(contentsOf: wiz.meetPushDiagnostics)
            guard let push = wiz.meetPushConfiguration
            else { throw MeetDMCallTrialError.missingPushConfiguration }
            self.context = Context(
                stored: context.stored, credentials: context.credentials, push: push,
                pushDiagnostics: wiz.meetPushDiagnostics
            )
            return push
        } catch {
            lines.append("Incoming watch config: " + Self.errorDescription(error))
            throw error
        }
    }

    private func loadCallClient(_ context: Context, generation: Int) async throws -> MeetCallClient {
        let accountIndex = switch endpoints.account {
        case let .index(index): index
        case .none: 0
        }
        let configuration = try await MeetCallBootstrap(
            transport: transport, credentials: context.credentials
        ).loadConfiguration(accountIndex: accountIndex, userAgent: endpoints.userAgent)
        lines.append("Meet call shell: client key found")
        lines.append("Meet RTC client header: validated client descriptor protobuf")
        try ensureGeneration(generation)
        return MeetCallClient(
            transport: transport, credentials: context.credentials, configuration: configuration,
            sha1: SHA1.hex
        )
    }

    private func discardIncoming(_ ticket: UUID) {
        guard let call = prepared, call.ticket == ticket, !call.permitsInvitation,
              native == nil else { return }
        prepared = nil
        generation += 1
        lines.append("Incoming call: abandoned preparation discarded before media")
    }

    private func validateWatch(_ stored: StoredSession, scope: UUID) async throws {
        try await ensureCurrent(stored)
        guard watchScope == scope else { throw MeetDMCallTrialError.superseded }
    }

    private func prepareIncoming(person: UUID, ring: MeetPushWire.Ring) async throws -> PreparedMeetDMCall {
        guard native == nil else { throw MeetDMCallTrialError.callNotPrepared }
        prepared = nil
        generation += 1
        let currentGeneration = generation
        guard let target = targets[person], let context else { throw MeetDMCallTrialError.invalidPerson }
        try await ensureCurrent(context.stored)
        let client = try await loadCallClient(context, generation: currentGeneration)
        let invitation = try MeetIncomingInvitation(id: ring.id, clientID: ring.receiverClientID)
        lines.append("ResolveMeetingSpace: resolving the offered incoming code (value withheld)")
        let call = try await client.resolveIncoming(code: ring.callIdentifier, invitation: invitation)
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        lines.append("ResolveMeetingSpace: offered incoming reference accepted (value withheld)")
        lines.append(MeetIncomingReference.diagnostic(ring.callIdentifier, call: call))
        guard call.resolvesIncomingReference(ring.callIdentifier) else {
            throw MeetDMCallTrialError.callChanged
        }
        let ticket = UUID()
        prepared = Prepared(
            ticket: ticket, generation: currentGeneration, target: target, context: context,
            client: client, call: call, ownerReportedBrowserJoin: false, permitsInvitation: false
        )
        lines
            .append(
                "Incoming call: offered reference matched; receiver invitation attached; invitations disabled"
            )
        return PreparedMeetDMCall(id: ticket, url: call.space.url)
    }
}

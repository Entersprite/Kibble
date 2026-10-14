import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// Owner-operated DM trial. Only explicit ring sends invitations; provider
/// IDs/tokens stay in this actor and public UUIDs are temporary handles.
public actor MeetDMCallTrial {
    struct Target: Sendable {
        let conversationID: Conversation.ID
        let dmID: String
        let calleeID: String
    }

    struct Context {
        let stored: StoredSession
        let credentials: SessionCredentials
        let push: MeetPushConfiguration?
        let pushDiagnostics: [String]
    }

    struct Prepared {
        let ticket: UUID
        let generation: Int
        let target: Target
        let context: Context
        let client: MeetCallClient
        let call: MeetResolvedCall
        let ownerReportedBrowserJoin: Bool
        let permitsInvitation: Bool
    }

    let store: KeychainCredentialStore
    let transport: any HTTPTransport
    let endpoints: ChatEndpoints
    let expectedSession: StoredSessionSummary?
    var sharedCredentials: SessionCredentials?
    var targets: [UUID: Target] = [:]
    var context: Context?
    var prepared: Prepared?
    var native: NativeMeetCallSession?
    var nativeScope: UUID?
    var generation = 0
    var lines = [
        "kibble native DM call trial",
        "Native audio/device trial; invitations are explicit and require a connected joined device.", ""
    ]

    public init(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        expectedSession: StoredSessionSummary? = nil
    ) {
        self.store = store
        self.transport = transport
        self.endpoints = endpoints
        self.expectedSession = expectedSession
    }

    public var report: String {
        get async {
            if let native {
                await lines.append(contentsOf: native.takeReport())
            }
            return lines.joined(separator: "\n")
        }
    }

    public func loadPeople(
        progress: @Sendable (MeetDMCallLoadStep) async -> Void = { _ in }
    ) async throws -> [MeetDMCallPerson] {
        await close()
        let currentGeneration = generation
        do {
            lines.append("Load people: started")
            try await loadProgress(.storedSession, generation: currentGeneration, progress: progress)
            let stored = try await loadStoredSession()
            lines.append("Stored Chat session: present")
            try await loadProgress(.chatBootstrap, generation: currentGeneration, progress: progress)
            let wiz = try await Bootstrap(transport: transport).run(
                cookies: currentCookies(for: stored),
                endpoints: endpoints
            )
            guard wiz.isSignedIn else { throw MeetDMCallTrialError.signedOut }
            lines.append("Chat bootstrap: accepted")
            let credentials = liveCredentials(for: stored)
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

    var watchScope = UUID()

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

    public func joinNative(
        preparedID: UUID, media: any CallMediaEngine,
        scope: UUID = UUID(),
        receive: (@Sendable (MeetNativeCallState) async -> Void)? = nil
    ) async throws {
        guard let call = prepared, call.ticket == preparedID, native == nil else {
            await media.close()
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
        nativeScope = scope
        do {
            try await session.connect()
            if let receive {
                await session.startMonitoring { [weak self, weak session] state in
                    if let session {
                        await self?.nativeStateChanged(state, session: session)
                    }
                    await receive(state)
                }
            }
            await lines.append(contentsOf: session.takeReport())
        } catch {
            await lines.append(contentsOf: session.takeReport())
            if native === session {
                native = nil
                nativeScope = nil
            }
            if prepared?.ticket == call.ticket {
                prepared = nil
            }
            throw error
        }
    }

    public func endNativeCall() async {
        guard let session = native else { return }
        native = nil
        nativeScope = nil
        await session.close()
        await lines.append(contentsOf: session.takeReport())
    }

    public func cancelNativeRing() async {
        guard let session = native else { return }
        await session.close(reason: .ringCancelled)
        await lines.append(contentsOf: session.takeReport())
        if native === session {
            native = nil
            nativeScope = nil
        }
    }

    private func nativeStateChanged(_ state: MeetNativeCallState, session: NativeMeetCallSession) async {
        guard native === session else { return }
        if case .ended = state {
            await lines.append(contentsOf: session.takeReport())
            native = nil
            nativeScope = nil
            prepared = nil
        }
    }

    private func validateNative(_ stored: StoredSession, generation: Int) async throws {
        try await ensureCurrent(stored)
        try ensureGeneration(generation)
    }

    public func setNativeMuted(_ muted: Bool, scope: UUID, sequence: UInt64) async throws -> Bool {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        let accepted = try await session.setMuted(muted, sequence: sequence)
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
        await lines.append(contentsOf: session.takeReport())
        return accepted
    }

    public func nativeOutgoingAudioReady(scope: UUID) async -> Bool {
        guard nativeScope == scope, let native else { return false }
        return await native.audioStream != nil
    }

    func ensureCurrent(_ expected: StoredSession) async throws {
        guard let stored = try await store.currentSession(),
              stored.capturedAt == expected.capturedAt, stored.expiresAt == expected.expiresAt
        else { throw MeetDMCallTrialError.accountChanged }
    }

    func ensureGeneration(_ expected: Int) throws {
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

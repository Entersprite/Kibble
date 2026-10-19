import Foundation
import GChatBridgeCore
import URLSessionTransport

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
            authorization: { [proof] jar, url in
                SAPISIDHash.browserAuthorization(for: .init(
                    cookies: jar.cookies, url: url, origin: "https://chat.google.com",
                    timestamp: Int(Date().timeIntervalSince1970)
                ), sha1: proof.sha1Hex)
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
            decline: { [weak self] ring in
                guard let self else { throw MeetDMCallTrialError.superseded }
                try await declineIncoming(ring, context: context, scope: scope)
            },
            discard: { [weak self] ticket in await self?.discardIncoming(ticket) }
        )
    }

    private func declineIncoming(_ ring: MeetPushWire.Ring, context: Context, scope: UUID) async throws {
        try await validateWatch(context.stored, scope: scope)
        guard let meetingToken = ring.meetingToken else {
            lines.append("Incoming decline: notification meeting token absent; request not sent")
            throw MeetCallClientError.missingMeetingToken
        }
        lines.append("Incoming decline: notification meeting token present (value withheld)")
        let current = generation
        let client = try await loadCallClient(context, generation: current)
        try await validateWatch(context.stored, scope: scope)
        try Task.checkCancellation()
        let invitation = try MeetIncomingInvitation(id: ring.id, clientID: ring.receiverClientID)
        let source = ring.notificationSource <= 2 ? String(ring.notificationSource) : "other"
        lines.append("Incoming decline: notification source selector " + source)
        let receipt = try await client.decline(
            invitation, meetingToken: meetingToken, recordsReceipt: ring.notificationSource != 2,
            validate: { [weak self] in
                guard let self else { throw MeetDMCallTrialError.superseded }
                try await validateWatch(context.stored, scope: scope)
                try await ensureGeneration(current)
            }
        )
        switch receipt {
        case .skipped: lines.append("LogEvent: receipt skipped for notification source2")
        case .acknowledged: lines.append("LogEvent: invitation receipt acknowledged")
        case let .unconfirmed(error):
            lines.append("LogEvent: invitation receipt unconfirmed; "
                + (error.map(Self.errorDescription) ?? "Request failed."))
        }
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

    func loadCallClient(_ context: Context, generation: Int) async throws -> MeetCallClient {
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
            sha1: proof.sha1Hex
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

import ChatKit
import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
    func joinNative(
        preparedID: UUID, media: any CallMediaEngine,
        scope: UUID = UUID(),
        receive: (@Sendable (MeetNativeCallState) async -> Void)? = nil,
        remoteMuted: (@Sendable (Bool?) async -> Void)? = nil,
        participants: (@Sendable ([CallParticipantDevice]?) async -> Void)? = nil
    ) async throws {
        guard let call = prepared, call.ticket == preparedID, native == nil else {
            await media.close()
            throw MeetDMCallTrialError.callNotPrepared
        }
        let session = NativeMeetCallSession(
            client: call.client, call: call.call, media: media, staysWhenAlone: call.isConversationCall,
            validateAccount: { [weak self] in
                guard let self else { throw MeetDMCallTrialError.superseded }
                try await validateNative(call.context.stored, generation: call.generation)
            }
        )
        await session.setParticipantHandler(participants)
        native = session
        nativeScope = scope
        cleanupScope = scope
        cleanupStatus = MeetNativeCallCleanup()
        do {
            try await session.connect()
            if let receive {
                await session.startMonitoring(receive: { [weak self, weak session] state in
                    if let session {
                        await self?.nativeStateChanged(state, session: session)
                    }
                    await receive(state)
                }, remoteMuted: remoteMuted)
            }
            await lines.append(contentsOf: session.takeReport())
        } catch {
            await lines.append(contentsOf: session.takeReport())
            await rememberCleanup(session, scope: scope)
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

    func endNativeCall() async {
        guard let session = native else { return }
        let scope = nativeScope
        native = nil
        nativeScope = nil
        await session.close()
        await rememberCleanup(session, scope: scope)
        await lines.append(contentsOf: session.takeReport())
    }

    func cancelNativeRing() async {
        guard let session = native else { return }
        let scope = nativeScope
        await session.close(reason: .ringCancelled)
        await rememberCleanup(session, scope: scope)
        await lines.append(contentsOf: session.takeReport())
        if native === session {
            native = nil
            nativeScope = nil
        }
    }

    private func nativeStateChanged(_ state: MeetNativeCallState, session: NativeMeetCallSession) async {
        guard native === session, state.isTerminal else { return }
        let scope = nativeScope
        let status = await session.cleanupStatus
        let report = await session.takeReport()
        guard native === session else { return }
        if cleanupScope == scope {
            cleanupStatus = status
        }
        lines.append(contentsOf: report)
        native = nil
        nativeScope = nil
        prepared = nil
    }

    private func rememberCleanup(_ session: NativeMeetCallSession, scope: UUID?) async {
        let status = await session.cleanupStatus
        if cleanupScope == scope {
            cleanupStatus = status
        }
    }

    internal func cleanupOutcome(for scope: UUID) -> MeetNativeCallCleanup {
        cleanupScope == scope ? cleanupStatus : MeetNativeCallCleanup()
    }

    private func validateNative(_ stored: StoredSession, generation: Int) async throws {
        try await ensureCurrent(stored)
        try ensureGeneration(generation)
    }

    func setNativeMuted(_ muted: Bool, scope: UUID, sequence: UInt64) async throws -> Bool {
        guard nativeScope == scope, let session = native else { throw MeetDMCallTrialError.superseded }
        let accepted = try await session.setMuted(muted, sequence: sequence)
        guard nativeScope == scope, native === session else { throw MeetDMCallTrialError.superseded }
        await lines.append(contentsOf: session.takeReport())
        return accepted
    }

    func nativeOutgoingAudioReady(scope: UUID) async -> Bool {
        guard nativeScope == scope, let native else { return false }
        return await native.audioStream != nil
    }
}

import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalBridgeAudioCallDiagnosticTests {
    let recipient = AudioCallRecipient(
        conversationID: .init("conversation-secret"), memberID: .init("member-secret"),
        displayName: "Person Secret"
    )

    @Test func matchingCurrentCallReturnsFixedStateAndOnDemandMediaReport() async throws {
        let engine = DiagnosticMedia()
        let service = LocalBridgeAudioCallService(mediaFactory: { engine })
        let id = UUID()
        service.snapshot = AudioCallSnapshot(
            id: id,
            recipient: recipient,
            direction: .outgoing,
            phase: .connected
        )
        service.media = engine
        let report = try #require(await service.diagnosticReport(callID: id))
        #expect(report.contains("Call phase: connected"))
        #expect(report.contains("Call direction: outgoing"))
        #expect(report.contains("Native microphone muted: false"))
        #expect(report.contains("Native audio samples: 2"))
        #expect(engine.reportRequests == 1)
        for secret in [id.uuidString, "conversation-secret", "member-secret", "Person Secret"] {
            #expect(!report.contains(secret))
        }
    }

    @Test func missingWrongAndStoppingCallsDoNotRequestMediaDiagnostics() async throws {
        let engine = DiagnosticMedia()
        let service = LocalBridgeAudioCallService(mediaFactory: { engine })
        let id = UUID()
        #expect(await service.diagnosticReport(callID: id) == nil)
        service.snapshot = AudioCallSnapshot(
            id: UUID(),
            recipient: recipient,
            direction: .incoming,
            phase: .incoming
        )
        service.media = engine
        #expect(await service.diagnosticReport(callID: id) == nil)
        service.isStopping = true
        #expect(try await service.diagnosticReport(callID: #require(service.snapshot?.id)) == nil)
        #expect(engine.reportRequests == 0)
    }

    @Test func unknownPhaseAndDirectionNeverExportTheirPayloads() async throws {
        let engine = DiagnosticMedia()
        let service = LocalBridgeAudioCallService(mediaFactory: { engine })
        let id = UUID()
        service.snapshot = AudioCallSnapshot(
            id: id, recipient: recipient, direction: .unknown("direction-secret"),
            phase: .unknown("phase-secret"), failureMessage: "failure-secret"
        )
        let report = try #require(await service.diagnosticReport(callID: id))
        #expect(report.contains("Call phase: unknown"))
        #expect(report.contains("Call direction: unknown"))
        #expect(report.contains("Native microphone muted: unavailable"))
        for secret in ["direction-secret", "phase-secret", "failure-secret"] {
            #expect(!report.contains(secret))
        }
    }

    @Test func reportSnapshotPreservesPendingNativeLinesAndSendsNoRequests() async throws {
        let engine = DiagnosticMedia()
        let transport = ScriptedTransport([NativeMeetFixture.responses()[0]])
        let native = try await NativeMeetFixture.session(transport, media: engine)
        await native.seedDiagnosticLines(["Native stream registration: acknowledged"])
        let trial = MeetDMCallTrial()
        await trial.seedDiagnosticNative(native)
        let service = LocalBridgeAudioCallService(trial: trial, mediaFactory: { engine })
        let id = UUID()
        service.snapshot = AudioCallSnapshot(
            id: id,
            recipient: recipient,
            direction: .outgoing,
            phase: .connected
        )
        service.media = engine
        let before = await native.lines
        let requests = await transport.sent.count
        let first = try #require(await service.diagnosticReport(callID: id))
        let second = try #require(await service.diagnosticReport(callID: id))
        #expect(first.contains("Native stream registration: acknowledged"))
        #expect(second.contains("Native stream registration: acknowledged"))
        #expect(await native.lines == before)
        #expect(await transport.sent.count == requests)
    }

    enum Change: CaseIterable {
        case call, callScope, session, media, stopping, stopped, cancelled
    }

    @Test(arguments: Change.allCases)
    func heldDiagnosticCannotEscapeReplacementTeardownOrCancellation(_ change: Change) async throws {
        let engine = DiagnosticMedia()
        engine.hold = true
        let service = LocalBridgeAudioCallService(mediaFactory: { engine })
        let id = UUID()
        service.snapshot = AudioCallSnapshot(
            id: id,
            recipient: recipient,
            direction: .outgoing,
            phase: .connected
        )
        service.media = engine
        let collecting = Task { await service.diagnosticReport(callID: id) }
        for _ in 0 ..< 10000 where engine.pending == nil {
            await Task.yield()
        }
        try #require(engine.pending != nil)
        switch change {
        case .call:
            service.snapshot = AudioCallSnapshot(
                id: UUID(),
                recipient: recipient,
                direction: .incoming,
                phase: .incoming
            )
        case .callScope: service.callScope = UUID()
        case .session: service.sessionScope = UUID()
        case .media: service.media = DiagnosticMedia()
        case .stopping: service.isStopping = true
        case .stopped: await service.stop()
        case .cancelled: collecting.cancel()
        }
        engine.resume()
        #expect(await collecting.value == nil)
        #expect(engine.reportRequests == 1)
    }
}

@MainActor
private final class DiagnosticMedia: CallMediaEngine {
    var isConnected = true
    var isMicrophoneMuted = false
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var reportRequests = 0

    func makeAudioOffer(serverControlChannel _: String?) async throws -> CallAudioOffer {
        throw CallMediaError.negotiationFailed
    }

    func applyAnswer(_: String) async throws {}
    func waitUntilConnected(timeout _: Duration) async throws {}
    func setMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    func close() {}
    func diagnosticReport() async -> [String] {
        reportRequests += 1
        if hold {
            await withCheckedContinuation { pending = $0 }
        }
        return ["Native audio samples: 2", "Audio RTP outbound packets delta: 12"]
    }

    func resume() {
        pending?.resume()
        pending = nil
    }
}

private extension MeetDMCallTrial {
    func seedDiagnosticNative(_ session: NativeMeetCallSession) {
        native = session
        nativeScope = UUID()
    }
}

private extension NativeMeetCallSession {
    func seedDiagnosticLines(_ entries: [String]) {
        lines = entries
    }
}

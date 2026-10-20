import AppCore
import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import MacHost

@MainActor
struct AudioCallDiagnosticExporterTests {
    @Test func nativeCallActionCopiesARefusalBeforeProviderSetup() async throws {
        let writes = DiagnosticWrites()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        exporter.install { _ in nil }
        let recipient = AudioCallRecipient(
            conversationID: .init("opaque-dm"), memberID: .init("peer"), displayName: "Private name"
        )
        let service = RefusedDiagnosticCallService(recipient: recipient)
        let calls = AudioCallController()
        let me = Member.ID("self")
        let person = Member(id: recipient.memberID, kind: .human)
        let dm = Conversation(id: recipient.conversationID, kind: .directMessage, members: [me, person.id])
        calls.start(service: service)
        try await diagnosticEventually { calls.canCall(conversation: dm, members: [person], me: me) }
        let id = try #require(calls.startCall(in: dm, members: [person], me: me))
        try await diagnosticEventually { calls.call?.phase == .failed }
        let actions = MacAppDelegate.callActions(
            for: id, calls: calls, audioDevices: CallAudioDeviceController(),
            video: CallVideoController(), diagnostics: exporter
        )
        let copy = try #require(actions.copyDiagnostics)
        #expect(await copy())
        #expect(writes.values.first?.contains("Call control failure: notAuthorized") == true)
        #expect(writes.values.first?.contains("Private name") == false)
        await calls.stop()
        #expect(await !copy())
        #expect(writes.values.count == 1)
    }

    @Test func preProviderFailureStillCopiesTheClientContext() async {
        let writes = DiagnosticWrites()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        exporter.install { _ in nil }
        #expect(await exporter.copy(
            callID: UUID(), context: "Call control failure: notAuthorized", isCurrent: { true }
        ))
        #expect(writes.values.first?.hasSuffix("Call control failure: notAuthorized") == true)
        #expect(await !exporter.copy(callID: UUID(), context: "retired", isCurrent: { false }))
        #expect(writes.values.count == 1)
    }

    @Test func aCurrentReportIsCopiedWithBuildContext() async {
        let writes = DiagnosticWrites()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        #expect(!exporter.isAvailable)
        let id = UUID()
        exporter.install { requested in requested == id ? "Audio packets sent: 42" : nil }
        #expect(exporter.isAvailable)
        #expect(await exporter.copy(callID: id, isCurrent: { true }))
        #expect(writes.values.count == 1)
        #expect(writes.values.first?.contains("Configuration:") == true)
        #expect(writes.values.first?.contains("Audio packets sent: 42") == true)
        exporter.install(nil)
        #expect(!exporter.isAvailable)
    }

    @Test func unavailableOrRetiredCallsNeverWriteTheClipboard() async {
        let writes = DiagnosticWrites()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        #expect(await !exporter.copy(callID: UUID(), isCurrent: { true }))
        exporter.install { _ in "must not copy" }
        #expect(await !exporter.copy(callID: UUID(), isCurrent: { false }))
        exporter.install { _ in nil }
        #expect(await !exporter.copy(callID: UUID(), isCurrent: { true }))
        #expect(writes.values.isEmpty)
    }

    @Test func replacementSessionRejectsALateReport() async throws {
        let writes = DiagnosticWrites()
        let gate = DiagnosticGate()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        exporter.install { _ in await gate.wait() }
        let copy = Task { await exporter.copy(callID: UUID(), context: "old context", isCurrent: { true }) }
        try await gate.started()
        exporter.install { _ in "replacement report" }
        gate.finish("old report")
        #expect(await !copy.value)
        #expect(writes.values.isEmpty)
        #expect(await exporter.copy(callID: UUID(), isCurrent: { true }))
        #expect(writes.values.first?.hasSuffix("replacement report") == true)
    }

    @Test func callReplacementRejectsALateReport() async throws {
        let writes = DiagnosticWrites()
        let gate = DiagnosticGate()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        let current = DiagnosticCurrentCall()
        exporter.install { _ in await gate.wait() }
        let copy = Task {
            await exporter.copy(callID: UUID(), context: "old context", isCurrent: { current.matches })
        }
        try await gate.started()
        current.matches = false
        gate.finish("retired report")
        #expect(await !copy.value)
        #expect(writes.values.isEmpty)
    }

    @Test func cancellationRejectsALateReport() async throws {
        let writes = DiagnosticWrites()
        let gate = DiagnosticGate()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        exporter.install { _ in await gate.wait() }
        let copy = Task { await exporter.copy(callID: UUID(), context: "old context", isCurrent: { true }) }
        try await gate.started()
        copy.cancel()
        gate.finish("cancelled report")
        #expect(await !copy.value)
        #expect(writes.values.isEmpty)
    }

    @Test func aNewerCopyRequestSupersedesAnOlderOne() async throws {
        let writes = DiagnosticWrites()
        let gate = DiagnosticGate()
        let exporter = AudioCallDiagnosticExporter { writes.values.append($0); return true }
        let firstID = UUID()
        exporter.install { id in id == firstID ? await gate.wait() : "new report" }
        let old = Task { await exporter.copy(callID: firstID, isCurrent: { true }) }
        try await gate.started()
        #expect(await exporter.copy(callID: UUID(), isCurrent: { true }))
        gate.finish("old report")
        #expect(await !old.value)
        #expect(writes.values.count == 1)
        #expect(writes.values.first?.hasSuffix("new report") == true)
    }
}

@MainActor private func diagnosticEventually(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition())
}

@MainActor private final class RefusedDiagnosticCallService: AudioCallService {
    let events: AsyncStream<AudioCallEvent>
    let sink: AsyncStream<AudioCallEvent>.Continuation
    let recipient: AudioCallRecipient

    init(recipient: AudioCallRecipient) {
        self.recipient = recipient
        (events, sink) = AsyncStream.makeStream()
    }

    func startListening() async throws {
        sink.yield(.recipientsChanged([recipient]))
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {
        throw ServiceFailure.notAuthorized
    }

    func accept(callID _: UUID) async throws {}
    func decline(callID _: UUID) async throws {}
    func hangUp(callID _: UUID) async throws {}
    func setMuted(_: Bool, callID _: UUID) async throws {}
    func stop() async {}
}

@MainActor private final class DiagnosticWrites {
    var values: [String] = []
}

@MainActor private final class DiagnosticCurrentCall {
    var matches = true
}

@MainActor private final class DiagnosticGate {
    private var continuation: CheckedContinuation<String?, Never>?

    func wait() async -> String? {
        await withCheckedContinuation { continuation = $0 }
    }

    func started() async throws {
        for _ in 0 ..< 1000 {
            if continuation != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(continuation != nil)
    }

    func finish(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

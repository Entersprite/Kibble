import ChatAPI
import ChatKit
import ChatService
import Foundation
import LocalBridgeBackend

/// Native presentation and hardware ports for exactly one provider generation.
@MainActor
final class NativeAccountCallBinding {
    let audioDevices = CallAudioDeviceController()
    let video = CallVideoController()
    let signIn = CallSignInRecovery()
    let diagnostics = AudioCallDiagnosticExporter()

    func install(_ source: LocalBridgeAudioCallService) async {
        video.isAvailable = true
        await signIn.install(load: { [weak source] in
            guard let source else { throw CancellationError() }
            return try await source.callSignInCookies()
        }, save: { [weak source] cookies in
            guard let source else { throw CancellationError() }
            return try await source.saveCallSignIn(cookies)
        })
        diagnostics.install { [weak source] id in await source?.diagnosticReport(callID: id) }
    }

    func makeMedia() -> any CallMediaEngine {
        NativeCallMedia(audioDevices: audioDevices, videoController: video)
    }

    func clearMedia() {
        audioDevices.clear()
        video.clear()
    }

    func retire() async {
        clearMedia()
        video.isAvailable = false
        diagnostics.install(nil)
        await signIn.invalidate()
    }
}

@MainActor
final class NativeAccountCallBindings {
    private struct Entry {
        let revision: ServiceAccountRevision
        weak var binding: NativeAccountCallBinding?
    }

    private var entries: [ConnectedAccountID: Entry] = [:]

    func install(_ binding: NativeAccountCallBinding, for account: AccountRecord) {
        entries = entries.filter { $0.value.binding != nil }
        entries[account.id] = Entry(revision: account.currentRevision, binding: binding)
    }

    func binding(for account: AccountSummary) -> NativeAccountCallBinding? {
        guard entries[account.id]?.revision == account.revision else { return nil }
        return entries[account.id]?.binding
    }
}

/// The provider stream stays FIFO, including its checked recovery barrier.
@MainActor
final class NativeAccountAudioCalls: AudioCallQuiescing {
    private let source: LocalBridgeAudioCallService
    private let binding: NativeAccountCallBinding
    var events: AsyncStream<AudioCallEvent> {
        source.events
    }

    init(source: LocalBridgeAudioCallService, binding: NativeAccountCallBinding) {
        self.source = source; self.binding = binding
    }

    func startListening() async throws {
        try await source.startListening()
    }

    func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        await source.updateRecipients(recipients)
    }

    func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        try await source.startOutgoing(to: recipient, callID: callID)
    }

    func accept(callID: UUID) async throws {
        try await source.accept(callID: callID)
    }

    func decline(callID: UUID) async throws {
        try await source.decline(callID: callID)
    }

    func hangUp(callID: UUID) async throws {
        try await source.hangUp(callID: callID)
    }

    func setMuted(_ muted: Bool, callID: UUID) async throws {
        try await source.setMuted(muted, callID: callID)
    }

    func pauseForRecovery(barrier: UUID) async throws {
        binding.clearMedia()
        try await source.pauseForRecovery(barrier: barrier)
    }

    func stop() async {
        await binding.retire()
        await source.stop()
    }
}

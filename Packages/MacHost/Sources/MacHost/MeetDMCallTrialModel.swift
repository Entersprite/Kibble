import AppKit
import Foundation
import LocalBridgeBackend
import Observation

public struct MeetCallTrialPerson: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let email: String?
}

/// Native controls for the owner-run invite-after-browser-join check. The model
/// exposes temporary handles; the bridge retains Google IDs and tokens.
@MainActor
@Observable
public final class MeetDMCallTrialModel {
    public private(set) var people: [MeetCallTrialPerson] = []
    public private(set) var selection: UUID?
    public internal(set) var isBusy = false
    public internal(set) var status = "Loading people from your DMs…"
    public internal(set) var invitationAccepted = false
    public private(set) var reportStatus = ""
    public private(set) var reportText = ""
    let trial = MeetDMCallTrial(store: KeychainCredentialStore(), proof: .native)
    var ticket: UUID?
    var link: URL?
    var hasOpenedBrowser = false
    var isReadyToRing = false
    var nativeMedia: NativeCallMedia?
    var microphoneRevision = UUID()
    var microphoneSequence: UInt64 = 0
    var microphoneTask: Task<Void, Never>?
    public internal(set) var nativeMicrophoneMuted = false
    public internal(set) var microphoneStatus = ""
    var nativeRevision = UUID()
    private var incoming: MeetIncomingDMCalls?
    private var listeningTask: Task<Void, Never>?
    private var listeningRevision = UUID()
    var isReceivingCall = false
    public private(set) var isListening = false
    public private(set) var incomingStatus = "Incoming call listening is stopped."
    public private(set) var incomingCall: IncomingMeetDMCall?
    public private(set) var isNativeCallActive = false
    public private(set) var isEndingNativeCall = false
    public internal(set) var nativeCallState: MeetNativeCallState?

    public var canCancelNativeRing: Bool {
        isNativeCallActive && !isEndingNativeCall && nativeCallState == .ringing
    }

    public init() {}

    public var selectedPerson: MeetCallTrialPerson? {
        people.first { $0.id == selection }
    }

    public var canPrepare: Bool {
        selection != nil && !isBusy && !isNativeCallActive && incomingCall == nil
    }

    public var canRing: Bool {
        ticket != nil && isReadyToRing && !isBusy
    }

    public var canOpenBrowser: Bool {
        link != nil && !isBusy
    }

    public var canConfirmBrowserJoin: Bool {
        ticket != nil && hasOpenedBrowser && !isReadyToRing && !isBusy
    }

    public var canJoinNative: Bool {
        ticket != nil && !isBusy && !isNativeCallActive && incomingCall == nil
    }

    public func select(_ person: UUID?) {
        guard !isBusy, !isNativeCallActive else { return }
        selection = person
        ticket = nil
        link = nil
        invitationAccepted = false
        nativeCallState = nil
        hasOpenedBrowser = false
        isReadyToRing = false
        status = "Prepare the call for the selected person."
    }

    public func load() async {
        guard !isBusy, !isNativeCallActive else { return }
        isBusy = true
        defer { isBusy = false }
        selection = nil
        ticket = nil
        link = nil
        invitationAccepted = false
        nativeCallState = nil
        hasOpenedBrowser = false
        isReadyToRing = false
        await stopListening()
        incoming = nil
        people = []
        status = "Loading people from your DMs…"
        do {
            people = try await trial.loadPeople(progress: { [weak self] step in
                await self?.updateLoadProgress(step)
            }).map {
                MeetCallTrialPerson(id: $0.id, name: $0.name, email: $0.email)
            }
            status = people.isEmpty
                ? "No named human DM recipients were found."
                : "Choose the person you want to test with, then prepare the call."
        } catch {
            people = []
            status = MeetDMCallTrial.errorDescription(error)
        }
        await saveReport()
    }

    public func joinNative() async {
        guard canJoinNative, let ticket else { return }
        let revision = UUID()
        nativeRevision = revision
        let media = NativeCallMedia()
        nativeMicrophoneMuted = false
        microphoneSequence = 0
        microphoneStatus = "Microphone is on. Connecting outgoing audio…"
        media.setMuted(false)
        nativeMedia = media
        nativeCallState = nil
        isNativeCallActive = true
        isBusy = true
        isReadyToRing = false
        status = "Connecting Kibble's native audio…"
        defer {
            if nativeRevision == revision {
                isBusy = false
            }
        }
        do {
            try await trial
                .joinNative(preparedID: ticket, media: media, scope: revision) { [weak self] state in
                    await self?.receiveNativeState(state, revision: revision)
                }
            guard nativeRevision == revision, isNativeCallActive else { return }
            let audioReady = await trial.nativeOutgoingAudioReady(scope: revision)
            guard nativeRevision == revision, isNativeCallActive else { return }
            microphoneStatus = audioReady
                ? "Microphone is on. Outgoing audio registered."
                : "Microphone is on locally. Outgoing audio registration unconfirmed."
            isReadyToRing = !isReceivingCall
            status = isReceivingCall
                ? "Incoming call joined with native audio. Check audio both ways."
                : "Kibble's native device is joined. You can now ring the selected person."
        } catch {
            guard nativeRevision == revision else { return }
            media.close()
            nativeMedia = nil
            microphoneStatus = "Outgoing audio is unavailable. Check the report."
            isNativeCallActive = false
            nativeCallState = .ended(.joinFailed)
            self.ticket = nil
            status = MeetDMCallTrial.errorDescription(error)
        }
        await saveReport()
    }

    public func endNativeCall() async {
        guard isNativeCallActive, !isEndingNativeCall else { return }
        isEndingNativeCall = true
        defer { isEndingNativeCall = false }
        nativeRevision = UUID()
        microphoneRevision = UUID()
        microphoneTask?.cancel()
        microphoneTask = nil
        nativeMicrophoneMuted = false
        microphoneStatus = ""
        ticket = nil
        isReadyToRing = false
        nativeMedia?.close()
        nativeMedia = nil
        isBusy = true
        nativeCallState = .ending
        status = "Ending the native call…"
        await trial.endNativeCall()
        isNativeCallActive = false
        nativeCallState = .ended(.localEnded)
        isBusy = false
        status = "Native audio closed. Check the report for Meet's device leave result."
        await saveReport()
    }

    public func close() async {
        await stopListening()
        incoming = nil
        nativeRevision = UUID()
        microphoneRevision = UUID()
        microphoneTask?.cancel()
        microphoneTask = nil
        nativeMicrophoneMuted = false
        microphoneStatus = ""
        nativeMedia?.close()
        nativeMedia = nil
        isNativeCallActive = false
        ticket = nil
        link = nil
        hasOpenedBrowser = false
        isReadyToRing = false
        await trial.close()
    }

    public var incomingPerson: MeetCallTrialPerson? {
        people.first { $0.id == incomingCall?.person }
    }

    public func startListening() async {
        guard !isListening, !isBusy, !people.isEmpty else { return }
        let revision = UUID()
        listeningRevision = revision
        isListening = true
        do {
            if incoming == nil {
                incoming = try await trial.incomingCalls()
            }
            guard listeningRevision == revision, let incoming else { return }
            listeningTask = Task { [weak self] in
                await incoming.run { [weak self] event in
                    await self?.receiveIncoming(event, revision: revision)
                }
                guard let self, listeningRevision == revision else { return }
                isListening = false
                await saveReport()
            }
        } catch {
            guard listeningRevision == revision else { return }
            isListening = false
            incomingStatus = MeetDMCallTrial.errorDescription(error)
            await saveReport()
        }
    }

    public func stopListening() async {
        listeningRevision = UUID()
        listeningTask?.cancel()
        listeningTask = nil
        isListening = false
        incomingCall = nil
        await incoming?.stop()
        incomingStatus = "Incoming call listening stopped."
    }

    public func declineIncoming() async {
        guard !isBusy, let incomingCall, let incoming else { return }
        let revision = listeningRevision
        isBusy = true
        defer { isBusy = false }
        incomingStatus = "Declining the incoming call…"
        do {
            try await incoming.decline(incomingCall.id)
            guard listeningRevision == revision else { return }
            incomingStatus = "Decline sent."
        } catch {
            guard listeningRevision == revision else { return }
            incomingStatus = "Decline was not confirmed. " + MeetDMCallTrial.errorDescription(error)
        }
        await saveReport()
    }

    public func acceptIncoming() async {
        guard !isBusy, !isNativeCallActive, let incomingCall, let incoming else { return }
        let revision = listeningRevision
        isBusy = true
        ticket = nil
        isReadyToRing = false
        isReceivingCall = true
        status = "Checking the incoming DM call…"
        do {
            let call = try await incoming.accept(incomingCall.id)
            guard listeningRevision == revision else {
                isBusy = false
                return
            }
            ticket = call.id
            link = call.url
            selection = incomingCall.person
            isBusy = false
            await joinNative()
        } catch {
            isBusy = false
            ticket = nil
            status = MeetDMCallTrial.errorDescription(error)
        }
        await saveReport()
    }

    private func receiveIncoming(_ event: MeetIncomingDMCalls.Event, revision: UUID) async {
        guard listeningRevision == revision else { return }
        switch event {
        case let .status(message): incomingStatus = message
        case .listening, .listeningFailed: break
        case let .ring(call):
            if isNativeCallActive || isBusy {
                await incoming?.dismiss(call.id)
            } else {
                incomingCall = call
                incomingStatus = "Incoming call from a loaded human DM."
            }
        case .cleared: incomingCall = nil
        }
        await saveReport()
    }

    public func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        reportStatus = "Report copied."
    }

    private func updateLoadProgress(_ step: MeetDMCallLoadStep) async {
        status = step.rawValue
        await saveReport()
    }

    func saveReport() async {
        let outgoingReport = await trial.report
        let receivingReport = await incoming?.report ?? ""
        let report = outgoingReport + "\n\n" + receivingReport
        reportText = report
        do {
            let directory = try SystemLaunchServices.supportDirectory()
            try Data(report.utf8).write(
                to: directory.appendingPathComponent("meet-call-probe.txt"), options: .atomic
            )
            reportStatus = "Report saved: meet-call-probe.txt"
        } catch {
            reportStatus = "Could not save the trial report."
        }
    }
}

extension MeetDMCallTrialModel {
    public func cancelNativeRing() async {
        guard canCancelNativeRing else { return }
        isEndingNativeCall = true
        defer { isEndingNativeCall = false }
        await trial.cancelNativeRing()
        await saveReport()
    }

    func receiveNativeState(_ state: MeetNativeCallState, revision: UUID) async {
        guard nativeRevision == revision else { return }
        nativeCallState = state
        status = state.message
        if state.isTerminal {
            microphoneRevision = UUID()
            microphoneTask?.cancel()
            microphoneTask = nil
            nativeMicrophoneMuted = false
            microphoneStatus = ""
            nativeRevision = UUID()
            isBusy = false
            nativeMedia = nil
            isNativeCallActive = false
            ticket = nil
            isReadyToRing = false
        }
        await saveReport()
    }
}

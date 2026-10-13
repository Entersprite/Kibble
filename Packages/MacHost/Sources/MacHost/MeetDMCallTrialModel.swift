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
    public private(set) var isBusy = false
    public private(set) var status = "Loading people from your DMs…"
    public private(set) var invitationAccepted = false
    public private(set) var reportStatus = ""
    public private(set) var reportText = ""
    private let trial = MeetDMCallTrial()
    private var ticket: UUID?
    private var link: URL?
    private var hasOpenedBrowser = false
    private var isReadyToRing = false
    private var nativeMedia: NativeCallMedia?
    private var nativeRevision = UUID()
    public private(set) var isNativeCallActive = false
    public private(set) var isEndingNativeCall = false

    public init() {}

    public var selectedPerson: MeetCallTrialPerson? {
        people.first { $0.id == selection }
    }

    public var canPrepare: Bool {
        selection != nil && !isBusy && !isNativeCallActive
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
        ticket != nil && !isBusy && !isNativeCallActive
    }

    public func select(_ person: UUID?) {
        guard !isBusy, !isNativeCallActive else { return }
        selection = person
        ticket = nil
        link = nil
        invitationAccepted = false
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
        hasOpenedBrowser = false
        isReadyToRing = false
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

    public func prepare() async {
        guard canPrepare, let selection else { return }
        isBusy = true
        defer { isBusy = false }
        ticket = nil
        link = nil
        invitationAccepted = false
        hasOpenedBrowser = false
        isReadyToRing = false
        status = "Preparing the DM call…"
        do {
            let prepared = try await trial.prepare(person: selection)
            ticket = prepared.id
            link = prepared.url
            status = "Call prepared. Connect native audio to join; "
                + "Ring stays disabled until Meet confirms the join."
        } catch {
            status = MeetDMCallTrial.errorDescription(error)
        }
        await saveReport()
    }

    public func joinNative() async {
        guard canJoinNative, let ticket else { return }
        let revision = UUID()
        nativeRevision = revision
        let media = NativeCallMedia()
        nativeMedia = media
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
            try await trial.joinNative(preparedID: ticket, media: media)
            guard nativeRevision == revision else { return }
            isReadyToRing = true
            status = "Kibble's native device is joined. You can now ring the selected person."
        } catch {
            guard nativeRevision == revision else { return }
            media.close()
            nativeMedia = nil
            isNativeCallActive = false
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
        ticket = nil
        isReadyToRing = false
        nativeMedia?.close()
        nativeMedia = nil
        isBusy = true
        status = "Ending the native call…"
        await trial.endNativeCall()
        isNativeCallActive = false
        isBusy = false
        status = "Native audio closed. Check the report for Meet's device leave result."
        await saveReport()
    }

    public func setNativeMuted(_ muted: Bool) {
        nativeMedia?.setMuted(muted)
    }

    public func confirmBrowserJoin() async {
        guard canConfirmBrowserJoin, let ticket else { return }
        isBusy = true
        defer { isBusy = false }
        self.ticket = nil
        isReadyToRing = false
        status = "Refreshing the prepared call after your browser join…"
        do {
            let prepared = try await trial.prepareRingAfterBrowserJoin(preparedID: ticket)
            self.ticket = prepared.id
            link = prepared.url
            isReadyToRing = true
            status = "Call refreshed. Stay joined in Meet, then ring the selected person."
        } catch {
            status = MeetDMCallTrial.errorDescription(error)
            if error is MeetDMCallTrialError {
                link = nil
                hasOpenedBrowser = false
            }
        }
        await saveReport()
    }

    public func ring() async {
        guard canRing, let ticket else { return }
        isBusy = true
        defer { isBusy = false }
        self.ticket = nil
        isReadyToRing = false
        status = "Sending the invitation…"
        do {
            try await trial.ring(preparedID: ticket)
            invitationAccepted = true
            status = "Invitation accepted. Check whether the other person rings "
                + "and whether audio works both ways."
        } catch {
            status = MeetDMCallTrial.errorDescription(error)
                + " End the native call when finished."
            if error is MeetDMCallTrialError {
                link = nil
                hasOpenedBrowser = false
                status = MeetDMCallTrial.errorDescription(error)
            }
        }
        await saveReport()
    }

    public func openCallInBrowser() {
        guard canOpenBrowser, let link else { return }
        if NSWorkspace.shared.open(link) {
            hasOpenedBrowser = true
            status = ticket != nil && !isReadyToRing
                ? "Join in Meet with your Kibble Google account, then return here and click I've Joined."
                : "Opened the call in your browser. Keep it joined while ringing; end the call in Meet."
        } else {
            status = "Could not open your default browser."
        }
    }

    public func close() async {
        nativeRevision = UUID()
        nativeMedia?.close()
        nativeMedia = nil
        isNativeCallActive = false
        ticket = nil
        link = nil
        hasOpenedBrowser = false
        isReadyToRing = false
        await trial.close()
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

    private func saveReport() async {
        let report = await trial.report
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

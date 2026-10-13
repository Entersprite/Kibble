import AppKit
import Foundation
import LocalBridgeBackend

@MainActor
public extension MeetDMCallTrialModel {
    func prepare() async {
        guard canPrepare, let selection else { return }
        isBusy = true
        defer { isBusy = false }
        ticket = nil
        link = nil
        invitationAccepted = false
        nativeCallState = nil
        hasOpenedBrowser = false
        isReadyToRing = false
        isReceivingCall = false
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

    func confirmBrowserJoin() async {
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

    func ring() async {
        guard canRing, let ticket else { return }
        let revision = nativeRevision
        isBusy = true
        defer {
            if nativeRevision == revision {
                isBusy = false
            }
        }
        self.ticket = nil
        isReadyToRing = false
        status = "Sending the invitation…"
        do {
            try await trial.ring(preparedID: ticket)
            guard nativeRevision == revision, isNativeCallActive || nativeCallState == nil else { return }
            invitationAccepted = true
            status = nativeCallState?.message ?? "Invitation sent. Waiting for the other person to join…"
        } catch {
            guard nativeRevision == revision else { return }
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

    func openCallInBrowser() {
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
}

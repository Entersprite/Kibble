import ChatKit
import SwiftUI

/// A section's draft as Info's sheet needs it (see `View.reportsInfoDraft`).
struct InfoDraftSeam {
    let section: InfoSection
    var isDirty: Bool
    /// False while the draft can't be sent.
    var isValid = true
    /// What Save sends; nil when there is nothing valid to send.
    var mutation: () -> ConversationMutation?
    /// Puts the draft back to `details`.
    var revert: () -> Void
    /// `details` changed; the flag says whether it answers this section's Save.
    var update: (_ details: ConversationDetails, _ isAnswer: Bool) -> Void
}

extension View {
    /// Plugs a section's draft into Info's sheet (see `InfoSectionDraft`):
    /// reports it while dirty and nil once clean, sends its one mutation on
    /// Save, and tells the section whether each new `details` is that Save's
    /// answer (start over from it) or a reload (keep the person's edits).
    func reportsInfoDraft(
        _ seam: InfoDraftSeam,
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        report: Binding<InfoSectionDraft?>
    ) -> some View {
        modifier(InfoDraftReporting(
            seam: seam, details: details, state: state, actions: actions, report: report
        ))
    }
}

private struct InfoDraftReporting: ViewModifier {
    let seam: InfoDraftSeam
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    @Binding var report: InfoSectionDraft?

    /// Whether the `details` arriving now answer this section's Save.
    @State private var saves = InfoSaveTracker()

    func body(content: Content) -> some View {
        content
            .onChange(of: details) { _, details in
                // A reload keeps what was chosen; the saved answer starts over.
                let browser = state.browser
                seam.update(
                    details,
                    saves.isAnswer(submitting: browser.isSubmitting, error: browser.panelError)
                )
            }
            .onChange(of: state.browser.isSubmitting) { _, submitting in
                saves.submittingChanged(submitting)
            }
            .task(id: saves.phase) {
                switch saves.phase {
                case .requested:
                    // A write the model dropped never starts submitting.
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled {
                        saves.saveMustHaveStarted()
                    }
                case .landing:
                    // Runs after the turn submitting ended in, and its `details`, were applied.
                    saves.landed()
                default:
                    break
                }
            }
            .onChange(of: reportKey, initial: true) { publish() }
    }

    /// What the sheet's copy of the draft depends on: its closures read the
    /// browser's flags and `details` as they were when it was made.
    private var reportKey: ReportKey {
        let browser = state.browser
        return ReportKey(
            details: details, isDirty: seam.isDirty, isValid: seam.isValid,
            blocked: browser.needsReconciliation || browser.isLoadingAllParticipants || browser.isSubmitting
        )
    }

    private struct ReportKey: Equatable {
        let details: ConversationDetails
        let isDirty: Bool
        let isValid: Bool
        let blocked: Bool
    }

    private func publish() {
        guard seam.isDirty else {
            if report != nil {
                report = nil
            }
            return
        }
        let blocked = reportKey.blocked
        report = InfoSectionDraft(
            section: seam.section,
            isValid: seam.isValid,
            save: {
                // The model drops a write while reconciling, loading or submitting.
                guard !blocked, let mutation = seam.mutation() else { return }
                saves.saveRequested()
                actions.mutate(mutation)
            },
            revert: seam.revert
        )
    }
}

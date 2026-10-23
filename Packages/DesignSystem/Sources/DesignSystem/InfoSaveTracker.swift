import Foundation

/// Whether a section's Save is the write in flight, so that the `details`
/// arriving as it ends is its answer: the draft starts over from it. Any
/// other `details` is a reload, and the draft keeps what was typed.
///
/// Save marks `requested`. Only seeing the model start submitting makes it
/// `submitting`; a write that hasn't started a moment later never will
/// (`saveMustHaveStarted`). When submitting ends the tracker is `landing`
/// for that one turn, so the `details` set in the same turn still counts,
/// and `landed()` after it returns to `idle`, whatever the outcome.
struct InfoSaveTracker: Equatable {
    enum Phase: Hashable {
        case idle, requested, submitting, landing
    }

    private(set) var phase = Phase.idle

    /// The section sent its Save.
    mutating func saveRequested() {
        phase = .requested
    }

    /// The model's `isSubmitting` changed.
    mutating func submittingChanged(_ submitting: Bool) {
        switch (phase, submitting) {
        case (.requested, true): phase = .submitting
        case (.submitting, false): phase = .landing
        default: break
        }
    }

    /// A moment after Save: a write the model dropped never starts.
    mutating func saveMustHaveStarted() {
        if phase == .requested {
            phase = .idle
        }
    }

    /// The turn the submission ended in is over, with its `details` applied.
    mutating func landed() {
        if phase == .landing {
            phase = .idle
        }
    }

    /// Whether `details` changing now is this Save's answer. Never while the
    /// model is still submitting: a reload landing mid-write is just a reload.
    func isAnswer(submitting: Bool) -> Bool {
        !submitting && (phase == .submitting || phase == .landing)
    }
}

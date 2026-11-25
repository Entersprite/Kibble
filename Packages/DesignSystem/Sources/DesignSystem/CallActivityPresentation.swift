import ChatKit
import SwiftUI

/// The sections of Meeting Activities, in the order the sheet shows them.
enum CallActivityTab: String, CaseIterable, Identifiable {
    case meeting = "Meeting"
    case chat = "Chat"
    case polls = "Polls"
    case questions = "Q&A"
    case rooms = "Rooms"

    var id: Self {
        self
    }
}

/// What the window says about recording, transcription and notes. The seam
/// carries their kind and phase as words of its own; nothing here shows one
/// of those words to a person.
enum CallArtifactPresentation {
    static func title(_ kind: String) -> String {
        switch kind {
        case "recording": "Recording"
        case "transcription": "Transcription"
        case "notes": "Notes"
        default: kind.capitalized
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "recording": "record.circle"
        case "transcription": "captions.bubble"
        case "notes": "note.text"
        default: "circle"
        }
    }

    /// Nil for a phase the window has no words for, which then shows nothing.
    static func status(_ phase: String) -> String? {
        switch phase {
        case "active": "On"
        case "starting": "Starting…"
        case "stopped", "preconfigured": "Off"
        default: nil
        }
    }

    static func status(for artifact: CallArtifact) -> String? {
        switch issue(for: artifact) {
        case .participantCompatibility: "Blocked by a participant’s device"
        case .initializationFailed: "Couldn’t start"
        case nil: status(artifact.phase)
        }
    }

    private static func issue(for artifact: CallArtifact) -> CallArtifactIssue? {
        switch (artifact.phase, artifact.issue.flatMap(CallArtifactIssue.init(rawValue:))) {
        case ("starting", .participantCompatibility): .participantCompatibility
        case ("stopped", .initializationFailed): .initializationFailed
        default: nil
        }
    }

    static func isRunning(_ phase: String) -> Bool {
        phase == "active" || phase == "starting"
    }

    static func canStart(_ phase: String) -> Bool {
        phase == "stopped" || phase == "preconfigured"
    }

    /// The line the call window shows for an ongoing attempt or its outcome.
    static func notice(for artifact: CallArtifact) -> String? {
        switch issue(for: artifact) {
        case .participantCompatibility: return "\(title(artifact.kind)) is blocked by a participant’s device"
        case .initializationFailed: return "\(title(artifact.kind)) couldn’t start"
        case nil: break
        }
        guard isRunning(artifact.phase) else { return nil }
        let starting = artifact.phase == "starting"
        switch artifact.kind {
        case "recording": return starting ? "Recording is starting" : "This call is being recorded"
        case "transcription": return starting ? "Transcription is starting" : "This call is being transcribed"
        case "notes": return starting ? "Notes are starting" : "Notes are being taken"
        default: return title(artifact.kind) + (starting ? " is starting" : " is on")
        }
    }

    static func startQuestion(_ kind: String) -> String {
        "Start \(title(kind))?"
    }

    /// One notice for each activity with visible progress or a known failure.
    static func notices(for artifacts: [CallArtifact]) -> [CallNotice] {
        artifacts.compactMap { artifact in
            notice(for: artifact).map {
                CallNotice(
                    id: "artifact/" + artifact.kind, text: $0,
                    kind: issue(for: artifact) == nil ? .info : .warning
                )
            }
        }
    }
}

/// Sends a reaction from the More menu, offered only while the meeting takes
/// them. A refusal shows as a notice in the call window, since the menu has
/// closed by the time the answer arrives.
@MainActor
enum CallReactionSender {
    static func action(for activities: CallActivitiesScene?, failed: Binding<Bool>) -> ((String) -> Void)? {
        guard let activities, activities.state.availableActions.contains("react") else { return nil }
        return { emoji in
            Task { @MainActor in
                do {
                    try await activities.perform(CallActivity("react", text: emoji))
                    failed.wrappedValue = false
                } catch is CancellationError {
                    // The call went away; there is nothing left to tell.
                } catch {
                    failed.wrappedValue = true
                }
            }
        }
    }
}

/// Takes the failed-reaction notice down again after a few seconds.
struct CallReactionFailureExpiry: ViewModifier {
    @Binding var failed: Bool

    func body(content: Content) -> some View {
        content.task(id: failed) {
            guard failed else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                failed = false
            }
        }
    }
}

/// How the sheet words its counts and its failures.
enum CallActivityCopy {
    static let refreshFailed = "Meeting activities couldn’t be refreshed."
    static let actionFailed = "That couldn’t be confirmed. Check the meeting before trying again."
    static let reactionFailed = "Your reaction couldn’t be sent."

    static let captureFailed = "The change couldn’t be confirmed. Check recording and transcription."

    static func failure(for activity: CallActivity) -> String {
        activity.action == "refresh" ? refreshFailed : actionFailed
    }

    /// Recording and transcription change as a pair; this says which half is in doubt.
    static func failure(for pair: CallArtifactPairError) -> String {
        switch pair {
        case .recordingUnconfirmed: "Transcription stopped, but recording couldn’t be confirmed."
        case .transcriptionUnconfirmed: "Recording changed, but transcription couldn’t be confirmed."
        case .bothUnconfirmed: "Neither change could be confirmed. Check recording and transcription."
        }
    }

    static func votes(_ count: Int) -> String {
        count == 1 ? "1 vote" : "\(count) votes"
    }

    /// The lines someone filled in, trimmed, in order.
    static func filled(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

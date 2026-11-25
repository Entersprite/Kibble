import ChatKit
import SwiftUI

/// Meeting Activities, a sheet over the call window: what the meeting keeps
/// (captions, recording, transcription, notes, attendance) and its host
/// controls, its chat, polls, questions and breakout rooms, one section at a
/// time.
///
/// A grouped form, as the app's other sheets are. A control is drawn only for
/// an action the meeting offers; one that is offered and cannot run right now
/// is disabled. Reactions are not here: they are one click away in the call's
/// More menu, where sending one does not need a sheet. Chat is a pane of its
/// own rather than form rows, because it scrolls and keeps its field in place.
struct CallActivitiesView: View {
    let scene: CallActivitiesScene
    @Environment(\.dismiss) private var dismiss
    @State var tab: CallActivityTab
    @State var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State var artifactToStart: String?
    @State var recordingCaptionLanguage = ""
    @Binding var drafts: CallActivityDrafts

    init(
        scene: CallActivitiesScene,
        drafts: Binding<CallActivityDrafts> = .constant(CallActivityDrafts()),
        initialTab: CallActivityTab = .meeting
    ) {
        self.scene = scene
        _tab = State(initialValue: initialTab)
        _drafts = drafts
    }

    var body: some View {
        // The sections sit above the form, not in a bar over it: a form
        // drawn under a bar started with its first rows behind the picker.
        VStack(spacing: 0) {
            header
            if tab == .chat {
                chatPane
            } else {
                Form {
                    if let error {
                        Section { SheetErrorRow(message: error) }
                    }
                    switch tab {
                    case .meeting: meeting
                    case .polls: polls
                    case .questions: questions
                    case .rooms: CallActivityRoomsView(
                            state: scene.state, currentRoomID: scene.currentBreakoutRoomID,
                            busy: busy, roomNames: $drafts.roomNames,
                            submit: { submit($0, accepted: $1) }
                        )
                    case .chat: EmptyView()
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .toolbar {
            // Done closes on Escape and takes no Return, which the fields use.
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { submit(CallActivity("refresh")) }
        .onDisappear { operation?.cancel() }
        .onChange(of: scene.state.recordingCaptionLanguages) {
            if !recordingCaptionLanguage.isEmpty,
               !scene.state.recordingCaptionLanguages.contains(recordingCaptionLanguage) {
                recordingCaptionLanguage = ""
                if artifactToStart == "recording" {
                    artifactToStart = nil
                }
            }
        }
        .confirmationDialog(
            artifactToStart.map(CallArtifactPresentation.startQuestion) ?? "",
            isPresented: Binding(get: { artifactToStart != nil }, set: { shown in
                if !shown {
                    artifactToStart = nil
                }
            }),
            presenting: artifactToStart
        ) { kind in
            Button("Start \(CallArtifactPresentation.title(kind))") {
                submit(CallActivity(
                    kind, recordingCaptionLanguage: kind == "recording" ? chosenLanguage : nil
                ))
            }
            if kind == "recording", canSetCapturePair(true) {
                Button("Start Recording and Transcription") { submitCapturePair(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everyone in the meeting is told. What it saves goes to the meeting’s organizer.")
        }
    }

    /// The sections, and the progress of whatever is on its way, which keeps
    /// its place so the bar never changes size. The sheet rereads the meeting
    /// when it opens and the call keeps it current, so there is no Refresh.
    private var header: some View {
        HStack(spacing: 12) {
            Picker("Section", selection: $tab) {
                ForEach(CallActivityTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ProgressView()
                .controlSize(.small)
                .opacity(busy ? 1 : 0)
                .accessibilityHidden(!busy)
                .frame(width: 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    /// The meeting's chat, with a failure above it, where the form's would be.
    private var chatPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                SheetErrorRow(message: error)
            }
            CallMeetingActivityChat(
                scene: scene, message: $drafts.message, waitingRoomMessage: $drafts.waitingRoomMessage,
                busy: busy, submit: { submit($0, accepted: $1) }
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Whether the meeting offers the action at all: what decides if its
    /// control is drawn.
    func offers(_ action: String) -> Bool {
        scene.state.availableActions.contains(action)
    }

    /// Whether the action can run now: not while another is on its way.
    func can(_ action: String) -> Bool {
        !busy && offers(action)
    }
}

extension CallActivitiesView {
    func submit(_ activity: CallActivity, accepted: (() -> Void)? = nil) {
        submit(failure: CallActivityCopy.failure(for: activity), accepted: accepted) {
            try await scene.perform(activity)
        }
    }

    func canSetCapturePair(_ enabled: Bool) -> Bool {
        scene.setRecordingAndTranscriptionEnabled != nil &&
            scene.state.canSetRecordingAndTranscriptionEnabled(enabled)
    }

    func submitCapturePair(_ enabled: Bool) {
        guard canSetCapturePair(enabled),
              let setEnabled = scene.setRecordingAndTranscriptionEnabled else { return }
        let language = enabled ? chosenLanguage : nil
        submit(failure: CallActivityCopy.captureFailed) {
            try await setEnabled(enabled, language)
        }
    }

    private func submit(
        failure: String,
        accepted: (() -> Void)? = nil,
        _ action: @escaping () async throws -> Void
    ) {
        guard !busy else { return }
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do {
                try await action()
                guard !Task.isCancelled else { return }
                accepted?()
            } catch let failure as CallArtifactPairError {
                guard !Task.isCancelled else { return }
                self.error = CallActivityCopy.failure(for: failure)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = failure
            }
        }
    }
}

/// A row saying a section has nothing in it yet.
struct CallActivityEmptyRow: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }
}

/// One field per line of a list someone types: a poll's answers, the names of
/// new rooms. Return in a field never adds a line or closes the sheet; Add
/// does, up to the limit. Empty fields are left out when the list is sent.
struct CallLineFields: View {
    @Binding var lines: [String]
    /// What one line is: "Option", "Room".
    let title: String

    var body: some View {
        ForEach(lines.indices, id: \.self) { index in
            TextField("\(title) \(index + 1)", text: Binding(
                get: { lines.indices.contains(index) ? lines[index] : "" },
                set: { text in
                    if lines.indices.contains(index) {
                        lines[index] = text
                    }
                }
            ))
        }
        if lines.count < CallActivityDrafts.lineLimit {
            Button("Add \(title)", systemImage: "plus") { lines.append("") }
                .buttonStyle(.borderless)
        }
    }
}

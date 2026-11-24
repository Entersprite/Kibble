import ChatKit
import SwiftUI

struct CallActivitiesView: View {
    let scene: CallActivitiesScene
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Meeting"
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @Binding private var message: String
    @Binding private var waitingRoomMessage: String
    @Binding private var question: String
    @Binding private var pollTitle: String
    @Binding private var pollOptions: String
    @Binding private var roomNames: String
    @Binding private var anonymous: Bool
    @State private var artifactToStart: String?
    @State var recordingCaptionLanguage = ""

    init(
        scene: CallActivitiesScene,
        drafts: Binding<CallActivityDrafts> = .constant(CallActivityDrafts()),
        initialTab: String = "Meeting"
    ) {
        self.scene = scene; _tab = State(initialValue: initialTab)
        _message = drafts.message; _waitingRoomMessage = drafts.waitingRoomMessage
        _question = drafts.question
        _pollTitle = drafts.pollTitle; _pollOptions = drafts.pollOptions
        _roomNames = drafts.roomNames; _anonymous = drafts.anonymous
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Meeting Activities").font(.headline)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { submit(CallActivity("refresh")) }
                    .disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Activities", selection: $tab) {
                ForEach(["Meeting", "Chat", "Polls", "Q&A", "Rooms"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case "Chat":
                        CallMeetingActivityChat(
                            scene: scene, message: $message, waitingRoomMessage: $waitingRoomMessage,
                            busy: busy, submit: submit
                        )
                    case "Polls": polls
                    case "Q&A": questions
                    case "Rooms": rooms
                    default: meeting
                    }
                }.disabled(busy).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
        .padding(20).frame(width: 560, height: 560)
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
        .confirmationDialog("Start meeting activity?", isPresented: Binding(
            get: { artifactToStart != nil }, set: {
                if !$0 {
                    artifactToStart = nil
                }
            }
        )) {
            if let kind = artifactToStart {
                Button("Start " + title(kind)) {
                    submit(CallActivity(
                        kind,
                        recordingCaptionLanguage: kind == "recording" ? chosenLanguage : nil
                    ))
                    artifactToStart = nil
                }
                if kind == "recording", canSetCapturePair(true) {
                    Button("Start Recording and Transcription") {
                        submitCapturePair(true)
                        artifactToStart = nil
                    }
                }
            }
        } message: {
            Text(
                "Participants will be notified. " +
                    "The meeting organizer receives the saved artifact through the meeting service."
            )
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 16) {
            if scene.state.availableActions.contains("captions") {
                CallCaptionControls(settings: scene.state.captions, languages: scene.state.captionLanguages) {
                    submit($0)
                }
                Divider()
            }
            Text("Reactions").font(.headline)
            HStack {
                ForEach(["❤️", "👍", "🎉", "👏", "😂", "😮", "😢", "🤔", "👎"], id: \.self) { emoji in
                    Button(emoji) { submit(CallActivity("react", text: emoji)) }
                        .font(.title2).buttonStyle(.plain).disabled(!can("react"))
                        .accessibilityLabel("React " + emoji)
                }
            }
            Divider()
            ForEach(scene.state.artifacts) { artifact in
                HStack {
                    VStack(alignment: .leading) {
                        Text(title(artifact.kind)).font(.headline)
                        Text(artifact.phase.capitalized).font(.caption).foregroundStyle(.secondary)
                        if let language = artifact.recordingCaptionLanguage {
                            Text("Captions in \(languageName(language))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if artifact.canSetEnabled(false) {
                        if artifact.kind == "recording", canSetCapturePair(false) {
                            Button("Stop Recording and Transcription") { submitCapturePair(false) }
                        }
                        Button("Stop") { submit(CallActivity(artifact.kind, enabled: false)) }
                            .disabled(!can(artifact.kind))
                    } else {
                        Button("Start…") { artifactToStart = artifact.kind }
                            .disabled(!can(artifact.kind) || !artifact.canSetEnabled(true))
                    }
                }
                if artifact.kind == "recording", artifact.canSetEnabled(true),
                   scene.state.availableActions.contains("recording"),
                   !scene.state.recordingCaptionLanguages.isEmpty {
                    recordingCaptionPicker
                }
            }
            if !scene.state.artifactFiles.isEmpty {
                ForEach(scene.state.artifactFiles) { file in
                    if file.url.scheme?.lowercased() == "https", file.url.host != nil {
                        Link(destination: file.url) {
                            Label(file.title ?? title(file.kind), systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            Divider()
            Toggle("Email attendance report to the organizer", isOn: Binding(
                get: { scene.state.attendanceReportEnabled == true },
                set: { submit(CallActivity("attendance", enabled: $0)) }
            ))
            .disabled(!can("attendance"))
            hostControls { submit($0) }
            Text("Availability depends on your account, meeting permissions, and organization settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var polls: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(scene.state.polls) { poll in
                VStack(alignment: .leading, spacing: 8) {
                    Text(poll.question).font(.headline)
                    ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                        HStack {
                            Text(option)
                            Spacer()
                            if poll.votes.indices
                                .contains(index) {
                                Text("\(poll.votes[index])").foregroundStyle(.secondary)
                            }
                            if poll.isOpen {
                                Button(poll.selections.contains(index) ? "Selected" : "Vote") {
                                    submit(CallActivity("votePoll", resourceID: poll.id, selections: [index]))
                                }.disabled(!can("votePoll"))
                            }
                        }
                    }
                    if let visible = poll.resultsVisible {
                        Toggle("Share results with everyone", isOn: Binding(
                            get: { visible },
                            set: { submit(CallActivity("sharePollResults", resourceID: poll.id, enabled: $0))
                            }
                        )).disabled(!can("sharePollResults"))
                    }
                    if poll.isOpen {
                        Button("End poll") { submit(CallActivity("closePoll", resourceID: poll.id)) }
                            .disabled(!can("closePoll"))
                    } else {
                        Text("Closed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            Text("Create a poll").font(.headline)
            TextField("Question", text: $pollTitle)
            TextField("Options, one per line", text: $pollOptions, axis: .vertical).lineLimit(2 ... 10)
            Button("Launch Poll") {
                submit(CallActivity("createPoll", text: pollTitle, options: lines(pollOptions))) {
                    pollTitle = ""; pollOptions = ""
                }
            }
            .disabled(!can("createPoll") || pollTitle.isEmpty || !(2 ... 10)
                .contains(lines(pollOptions).count))
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(scene.state.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text).textSelection(.enabled)
                    HStack {
                        Button(
                            "\(question.votes) votes",
                            systemImage: question.hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup"
                        ) {
                            submit(CallActivity(
                                "voteQuestion",
                                resourceID: question.id,
                                enabled: !question.hasVoted
                            ))
                        }.disabled(!can("voteQuestion"))
                        Spacer()
                        if question.isAnswered {
                            Label("Answered", systemImage: "checkmark")
                        } else {
                            Button("Mark Answered") { submit(CallActivity(
                                "answerQuestion",
                                resourceID: question.id
                            )) }
                            .disabled(!can("answerQuestion"))
                        }
                    }
                }
                Divider()
            }
            TextField("Ask a question", text: $question, axis: .vertical).lineLimit(2 ... 5)
            Toggle("Ask anonymously", isOn: $anonymous)
                .disabled(!can("askQuestion") || scene.state.allowsAnonymousQuestions != true)
                .onChange(of: scene.state.allowsAnonymousQuestions) { _, allowed in
                    if allowed != true {
                        anonymous = false
                    }
                }
            Button("Ask") {
                submit(CallActivity(
                    "askQuestion",
                    text: question,
                    enabled: !(anonymous && scene.state.allowsAnonymousQuestions == true)
                )) {
                    question = ""
                }
            }
            .disabled(!can("askQuestion") || question.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
        }
    }

    private var rooms: some View {
        CallActivityRoomsView(state: scene.state, busy: busy, roomNames: $roomNames, submit: submit)
    }

    private func title(_ kind: String) -> String {
        kind == "notes" ? "Notes" : kind.capitalized
    }

    private func can(_ action: String) -> Bool {
        !busy && scene.state.availableActions.contains(action)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension CallActivitiesView {
    func submit(_ activity: CallActivity, accepted: (() -> Void)? = nil) {
        let failure = activity.action == "refresh" ? "Meeting activities could not be refreshed." :
            "The action was refused or could not be confirmed. Check the meeting state before trying again."
        submit(failure: failure, accepted: accepted) { try await scene.perform(activity) }
    }

    func canSetCapturePair(_ enabled: Bool) -> Bool {
        scene.setRecordingAndTranscriptionEnabled != nil &&
            scene.state.canSetRecordingAndTranscriptionEnabled(enabled)
    }

    func submitCapturePair(_ enabled: Bool) {
        guard canSetCapturePair(enabled),
              let setEnabled = scene.setRecordingAndTranscriptionEnabled else { return }
        let failure = "The capture change could not be confirmed. Check its status before trying again."
        let language = enabled ? chosenLanguage : nil
        submit(failure: failure) {
            try await setEnabled(enabled, language)
        }
    }

    func submit(
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
                self.error = switch failure {
                case .recordingUnconfirmed:
                    "Transcription stopped. Check the recording status before trying again."
                case .transcriptionUnconfirmed:
                    "The recording change was confirmed. Check the transcription status before trying again."
                case .bothUnconfirmed:
                    "Neither stop could be confirmed. Check both activity statuses before trying again."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = failure
            }
        }
    }
}

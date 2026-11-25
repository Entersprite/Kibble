import ChatKit
import SwiftUI

extension CallActivitiesView {
    /// Captions, then recording, transcription and notes with what they
    /// saved, the attendance report, and the host's controls.
    @ViewBuilder var meeting: some View {
        let artifacts = scene.state.artifacts
        let files = scene.state.artifactFiles
            .filter { $0.url.scheme?.lowercased() == "https" && $0.url.host != nil }
        let showsAttendance = offers("attendance") || scene.state.attendanceReportEnabled != nil
        // Captions and the host's controls bring their own sections and
        // headers, so they sit at the form's top level, not inside one here.
        if offers("captions") {
            CallCaptionControls(settings: scene.state.captions, languages: scene.state.captionLanguages) {
                submit($0)
            }
        }
        if !artifacts.isEmpty || !files.isEmpty {
            Section {
                ForEach(artifacts) { artifact in
                    artifactRow(artifact)
                    if artifact.kind == "recording", artifact.canSetEnabled(true), offers("recording"),
                       !scene.state.recordingCaptionLanguages.isEmpty {
                        recordingCaptionPicker
                    }
                }
                ForEach(files) { file in
                    Link(destination: file.url) {
                        Label(
                            file.title ?? CallArtifactPresentation.title(file.kind),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .help("Open in your browser")
                }
            } footer: {
                Text("What you can start depends on your account, the meeting and your organization.")
            }
        }
        if showsAttendance {
            Section {
                Toggle("Email the Attendance Report to the Organizer", isOn: Binding(
                    get: { scene.state.attendanceReportEnabled == true },
                    set: { submit(CallActivity("attendance", enabled: $0)) }
                ))
                .disabled(!can("attendance"))
            }
        }
        if scene.state.hostSettings != nil {
            hostControls { submit($0) }
                .disabled(busy)
        }
        if !offers("captions"), artifacts.isEmpty, files.isEmpty, !showsAttendance,
           scene.state.hostSettings == nil {
            Section { CallActivityEmptyRow(text: "This meeting has nothing to manage.") }
        }
    }

    /// Start…, or Stop. Where recording and transcription can stop together,
    /// Stop is a menu naming both choices rather than two buttons in a row.
    private func artifactRow(_ artifact: CallArtifact) -> some View {
        let pairedStop = artifact.kind == "recording" && canSetCapturePair(false)
        return HStack {
            LabeledContent {
                if !pairedStop {
                    if artifact.canSetEnabled(false) {
                        Button("Stop") { submit(CallActivity(artifact.kind, enabled: false)) }
                            .disabled(!can(artifact.kind))
                            .accessibilityLabel("Stop \(CallArtifactPresentation.title(artifact.kind))")
                    } else {
                        Button("Start…") { artifactToStart = artifact.kind }
                            .disabled(!can(artifact.kind) || !artifact.canSetEnabled(true))
                            .accessibilityLabel("Start \(CallArtifactPresentation.title(artifact.kind))")
                    }
                }
            } label: {
                Text(CallArtifactPresentation.title(artifact.kind))
                if let status = Self.status(of: artifact, languageName: languageName) {
                    Text(status)
                }
            }
            if pairedStop {
                // LabeledContent combines its children and can hide the menu from accessibility.
                Menu("Stop") {
                    Button("Stop Recording") { submit(CallActivity(artifact.kind, enabled: false)) }
                    Button("Stop Recording and Transcription") { submitCapturePair(false) }
                }
                .fixedSize()
                .disabled(!can(artifact.kind))
                .accessibilityLabel("Stop Recording")
            }
        }
    }

    /// "On", and the language its captions are saved in when one is confirmed.
    static func status(of artifact: CallArtifact, languageName: (String) -> String) -> String? {
        let status = CallArtifactPresentation.status(for: artifact)
        guard let language = artifact.recordingCaptionLanguage else { return status }
        let captions = "Captions in \(languageName(language))"
        return status.map { $0 + " · " + captions } ?? captions
    }

    @ViewBuilder var polls: some View {
        if scene.state.polls.isEmpty {
            Section { CallActivityEmptyRow(text: "No polls yet.") }
        }
        ForEach(scene.state.polls) { poll in
            Section {
                ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                    pollOption(option, at: index, in: poll)
                }
                if let visible = poll.resultsVisible, offers("sharePollResults") {
                    Toggle("Share Results with Everyone", isOn: Binding(
                        get: { visible },
                        set: { submit(CallActivity("sharePollResults", resourceID: poll.id, enabled: $0)) }
                    ))
                    .disabled(!can("sharePollResults"))
                }
                if poll.isOpen, offers("closePoll") {
                    Button("End Poll") { submit(CallActivity("closePoll", resourceID: poll.id)) }
                        .disabled(!can("closePoll"))
                }
            } header: {
                Text(poll.question)
            } footer: {
                if !poll.isOpen {
                    Text("This poll has ended.")
                }
            }
        }
        if offers("createPoll") {
            Section("New Poll") {
                TextField("Question", text: $drafts.pollTitle)
                CallLineFields(lines: $drafts.pollOptions, title: "Option")
                Button("Start Poll") {
                    submit(CallActivity(
                        "createPoll", text: drafts.pollTitle,
                        options: CallActivityCopy.filled(drafts.pollOptions)
                    )) {
                        drafts.pollTitle = ""
                        drafts.pollOptions = CallActivityDrafts.emptyPollOptions
                    }
                }
                .disabled(
                    !can("createPoll") || isBlank(drafts.pollTitle)
                        || CallActivityCopy.filled(drafts.pollOptions).count < 2
                )
            }
        }
    }

    /// An answer, its count where the meeting shows one, and the person's
    /// vote: a checkmark on the answer they chose, Vote on the others.
    private func pollOption(_ option: String, at index: Int, in poll: CallPoll) -> some View {
        HStack(spacing: 10) {
            Text(option)
            Spacer(minLength: 10)
            if poll.votes.indices.contains(index) {
                Text(CallActivityCopy.votes(poll.votes[index]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if poll.selections.contains(index) {
                Label("Your vote for \(option)", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
            } else if poll.isOpen, offers("votePoll") {
                Button("Vote") {
                    submit(CallActivity("votePoll", resourceID: poll.id, selections: [index]))
                }
                .controlSize(.small)
                .disabled(!can("votePoll"))
                .accessibilityLabel("Vote for \(option)")
            }
        }
    }

    @ViewBuilder var questions: some View {
        Section {
            if scene.state.questions.isEmpty {
                CallActivityEmptyRow(text: "No questions yet.")
            }
            ForEach(scene.state.questions) { question in
                questionRow(question)
            }
        }
        if offers("askQuestion") {
            let allowsAnonymous = scene.state.allowsAnonymousQuestions == true
            Section("Ask a Question") {
                TextField("Question", text: $drafts.question, prompt: Text("Your question"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1 ... 4)
                if allowsAnonymous {
                    Toggle("Ask Anonymously", isOn: $drafts.anonymous)
                }
                Button("Ask") {
                    submit(CallActivity(
                        "askQuestion", text: drafts.question,
                        enabled: !(drafts.anonymous && allowsAnonymous)
                    )) {
                        drafts.question = ""
                    }
                }
                .disabled(!can("askQuestion") || isBlank(drafts.question))
            }
            .onChange(of: allowsAnonymous) { _, allowed in
                if !allowed {
                    drafts.anonymous = false
                }
            }
        }
    }

    private func questionRow(_ question: CallQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text).textSelection(.enabled)
            HStack {
                Button(
                    CallActivityCopy.votes(question.votes),
                    systemImage: question.hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup"
                ) {
                    submit(CallActivity("voteQuestion", resourceID: question.id, enabled: !question.hasVoted))
                }
                .buttonStyle(.borderless)
                .disabled(!can("voteQuestion"))
                .help(question.hasVoted ? "Remove your vote" : "Vote for this question")
                Spacer()
                if question.isAnswered {
                    Label("Answered", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if offers("answerQuestion") {
                    Button("Mark as Answered") {
                        submit(CallActivity("answerQuestion", resourceID: question.id))
                    }
                    .controlSize(.small)
                    .disabled(!can("answerQuestion"))
                }
            }
        }
    }

    func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

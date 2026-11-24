import ChatKit
import SwiftUI

extension CallActivitiesView {
    var chosenLanguage: String? {
        recordingCaptionLanguage.isEmpty ? nil : recordingCaptionLanguage
    }

    var recordingCaptionPicker: some View {
        Picker("Recording Captions", selection: $recordingCaptionLanguage) {
            Text("Off").tag("")
            ForEach(scene.state.recordingCaptionLanguages, id: \.self) { language in
                Text(languageName(language)).tag(language)
            }
        }
    }

    func languageName(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }
}

struct CallCaptionLabel: View {
    let segment: CallCaptionSegment?
    @State private var expired: CallCaptionSegment?

    init(call: AudioCallSession, state: CallActivitiesState?) {
        segment = call.phase == .connected ? state?.captions?.segments.last : nil
    }

    var body: some View {
        if let segment, expired != segment {
            // Light text on a dark plate, as captions are everywhere, so the
            // words read over any video; no wider than the audio column.
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker {
                    Text(speaker).font(.caption).fontWeight(.semibold).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(segment.text).font(.callout).lineLimit(3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
            .task(id: segment) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                expired = segment
            }
        }
    }
}

struct CallCaptionControls: View {
    let settings: CallCaptionState?
    let languages: CallCaptionLanguages?
    let submit: (CallActivity) -> Void
    @State private var preferences: CallCaptionSelection

    init(
        settings: CallCaptionState?,
        languages: CallCaptionLanguages?,
        submit: @escaping (CallActivity) -> Void
    ) {
        self.settings = settings
        self.languages = languages
        self.submit = submit
        let spoken = settings?.spokenLanguage ?? "en-US"
        let display = settings?.displayLanguage ?? spoken
        _preferences = State(initialValue: CallCaptionSelection(
            spoken: spoken, translated: display != spoken ? display : ""
        ))
    }

    var body: some View {
        // A switch for the captions themselves, bound to what the meeting
        // confirmed, then the languages. Changing a language while captions
        // are on is its own explicit step, so nothing is sent by browsing a menu.
        Section {
            Toggle("Live Captions", isOn: Binding(
                get: { settings != nil },
                set: { isOn in
                    if isOn {
                        apply()
                    } else {
                        submit(CallActivity("captions", enabled: false))
                    }
                }
            ))
            .disabled(settings == nil && !canApply)
            Picker("Meeting Language", selection: Binding(
                get: { selection.spoken },
                set: { preferences = CallCaptionSelection(spoken: $0, translated: selection.translated) }
            )) {
                choices(available.meetingLanguages)
            }
            if let targets = available.translations[selection.spoken], !targets.isEmpty {
                Picker("Translate To", selection: Binding(
                    get: { selection.translated },
                    set: { preferences = CallCaptionSelection(spoken: selection.spoken, translated: $0) }
                )) {
                    if available.live.contains(selection.spoken) {
                        Text("Off").tag("")
                    }
                    choices(targets)
                }
            }
            if settings != nil, differsFromConfirmed {
                Button("Use These Languages", action: apply).disabled(!canApply)
            }
        } header: {
            Text("Captions")
        }
    }

    private var canApply: Bool {
        available.supports(spoken: selection.spoken, display: selection.display)
    }

    private var differsFromConfirmed: Bool {
        settings?.spokenLanguage != selection.spoken || settings?.displayLanguage != selection.display
    }

    private func apply() {
        guard canApply else { return }
        submit(CallActivity("captions", options: [selection.spoken, selection.display]))
    }

    private var available: CallCaptionLanguages {
        languages ?? Self.fallback
    }

    private var selection: CallCaptionSelection {
        preferences.resolved(in: available)
    }

    private func choices(_ tags: [String]) -> some View {
        ForEach(tags, id: \.self) { code in
            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
        }
    }

    private static let fallback: CallCaptionLanguages = {
        let tags = ["en-US", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR", "ja-JP"]
        return CallCaptionLanguages(
            live: tags,
            translations: Dictionary(uniqueKeysWithValues: tags.map { spoken in
                (spoken, tags.filter { $0 != spoken })
            })
        )
    }()
}

struct CallCaptionSelection: Equatable {
    let spoken: String
    let translated: String

    var display: String {
        translated.isEmpty ? spoken : translated
    }

    func resolved(in languages: CallCaptionLanguages) -> Self {
        let available = languages.meetingLanguages
        let spoken = available.contains(spoken) ? spoken : languages.live.first ?? available.first ?? ""
        let targets = languages.translations[spoken] ?? []
        let display = targets.contains(translated) ? translated
            : languages.live.contains(spoken) ? "" : targets.first ?? ""
        return CallCaptionSelection(spoken: spoken, translated: display)
    }
}

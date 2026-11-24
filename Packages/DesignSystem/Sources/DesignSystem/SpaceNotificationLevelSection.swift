import ChatKit
import SwiftUI

public struct SpaceNotificationSetting {
    let level: NotificationLevel
    let muted: Bool
    let muteUntil: Date?
    let canSave: Bool
    let save: (NotificationLevel) async throws -> Void

    public init(
        level: NotificationLevel, muted: Bool, canSave: Bool, muteUntil: Date? = nil,
        save: @escaping (NotificationLevel) async throws -> Void
    ) {
        self.level = level
        self.muted = muted
        self.muteUntil = muteUntil
        self.canSave = canSave
        self.save = save
    }
}

struct SpaceNotificationLevelSection: View {
    let setting: SpaceNotificationSetting
    let now: Date
    @State private var draft: NotificationLevel?
    @State private var confirmed: NotificationLevel?
    @State private var save: Task<Void, Never>?
    @State private var failed = false

    private static let choices: [NotificationLevel] = [.always, .lessWithNewThreads, .less, .never]

    var body: some View {
        section(isMuted: setting.muted && (setting.muteUntil.map { $0 > now } ?? true))
            .onChange(of: setting.level) { _, _ in confirmed = nil }
            .onChange(of: setting.muted) { _, _ in confirmed = nil }
            .onChange(of: setting.muteUntil) { _, _ in confirmed = nil }
            .onDisappear { save?.cancel() }
    }

    private func section(isMuted: Bool) -> some View {
        let canSaveLevel = hasChange(isMuted: isMuted)
        return Section {
            Picker("Notify about", selection: Binding(
                get: { selection },
                set: { draft = $0; failed = false }
            )) {
                if !Self.choices.contains(setting.level) {
                    Text("Current level unavailable").tag(setting.level)
                }
                ForEach(Self.choices, id: \.self) { level in
                    Text(title(for: level)).tag(level)
                }
            }
            LabeledContent {
                Button("Save Space Setting") { saveLevel(isMuted: isMuted) }
                    .disabled(!setting.canSave || save != nil || !canSaveLevel)
            } label: {
                if save != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving space setting")
                }
            }
        } header: {
            Text("Space Notifications")
        } footer: {
            if failed {
                Text("Couldn’t confirm the space setting. Check the current setting before saving again.")
            } else if isMuted, confirmed == nil {
                Text("Saving a level also unmutes this space.")
            } else {
                Text("Applies across your Chat clients.")
            }
        }
        .disabled(save != nil)
    }

    private func hasChange(isMuted: Bool) -> Bool {
        Self.choices.contains(selection)
            && (selection != (confirmed ?? setting.level) || (isMuted && confirmed == nil))
    }

    private var selection: NotificationLevel {
        draft ?? confirmed ?? setting.level
    }

    private func saveLevel(isMuted: Bool) {
        guard hasChange(isMuted: isMuted), setting.canSave, save == nil else { return }
        let level = selection
        failed = false
        save = Task {
            defer { save = nil }
            do {
                try await setting.save(level)
                try Task.checkCancellation()
                confirmed = level
                draft = nil
            } catch {
                if !Task.isCancelled {
                    failed = true
                }
            }
        }
    }

    private func title(for level: NotificationLevel) -> String {
        switch level {
        case .always: "All messages and threads"
        case .lessWithNewThreads: "Main conversations and followed threads"
        case .less: "Mentions and followed threads"
        case .never: "No notifications"
        case .unknown: "Current level unavailable"
        }
    }
}

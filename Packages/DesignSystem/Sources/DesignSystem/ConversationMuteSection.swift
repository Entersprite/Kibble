import ChatKit
import SwiftUI

public struct ConversationMuteSetting {
    let pause: Pause
    let canSave: Bool
    let save: (Pause) async throws -> Void

    public init(pause: Pause, canSave: Bool, save: @escaping (Pause) async throws -> Void) {
        self.pause = pause
        self.canSave = canSave
        self.save = save
    }
}

struct ConversationMuteSection: View {
    let setting: ConversationMuteSetting
    let now: Date
    let showsScope: Bool
    @Environment(\.calendar) private var calendar
    @State private var customTime: Date?
    @State private var save: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        let muted = setting.pause.isActive(at: now)
        return Section {
            LabeledContent {
                Menu(muted ? "Change Mute…" : "Mute…") {
                    if muted {
                        Button("Unmute") { submit(.off) }
                        Divider()
                    }
                    Button("For 1 Hour") { submit(.until(.now.addingTimeInterval(3600))) }
                    Button("For 4 Hours") { submit(.until(.now.addingTimeInterval(4 * 3600))) }
                    Button("Until Next Workday") {
                        if let nextWorkday = Self.nextWorkday(from: .now, calendar: calendar) {
                            submit(.until(nextWorkday))
                        }
                    }
                    Button("Until I Unmute") { submit(.untilResumed) }
                    Button("Until a Custom Time…") { customTime = .now.addingTimeInterval(3600) }
                }
                .disabled(!setting.canSave || save != nil)
            } label: {
                if muted, case let .until(end) = setting.pause {
                    Text("Muted until \(end.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text(muted ? "Muted" : "Notifications Active")
                }
            }
            if let customTime {
                customTimeEditor(customTime, now: now)
            }
            if save != nil {
                ProgressView().controlSize(.small).accessibilityLabel("Saving mute setting")
            }
        } header: {
            Text("Conversation Mute")
        } footer: {
            if failed {
                Text("Couldn’t confirm the mute setting. Check the current setting before trying again.")
            } else if showsScope {
                Text("Applies across your Chat clients.")
            }
        }
        .onDisappear { save?.cancel() }
    }

    private func customTimeEditor(_ date: Date, now: Date) -> some View {
        let latest = now.addingTimeInterval(120 * 86400)
        return Group {
            DatePicker("Mute until", selection: Binding(
                get: { customTime ?? date }, set: { customTime = $0 }
            ), in: now ... latest)
                .disabled(save != nil)
            HStack {
                Spacer()
                Button("Cancel") { customTime = nil }
                    .disabled(save != nil)
                Button("Mute Conversation") { submit(.until(date)) }
                    .disabled(!setting.canSave || save != nil || date <= now || date > latest)
            }
        }
    }

    private func submit(_ pause: Pause) {
        guard save == nil, setting.canSave else { return }
        failed = false
        save = Task {
            defer { save = nil }
            do {
                try await setting.save(pause)
                try Task.checkCancellation()
                customTime = nil
            } catch {
                if !Task.isCancelled {
                    failed = true
                }
            }
        }
    }

    nonisolated static func nextWorkday(from now: Date, calendar: Calendar) -> Date? {
        let offset = calendar.component(.hour, from: now) < 4 ? 0 : 1
        let start = calendar.startOfDay(for: now)
        for days in offset ..< offset + 3 {
            guard let day = calendar.date(byAdding: .day, value: days, to: start),
                  (2 ... 6).contains(calendar.component(.weekday, from: day))
            else { continue }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)
        }
        return nil
    }
}

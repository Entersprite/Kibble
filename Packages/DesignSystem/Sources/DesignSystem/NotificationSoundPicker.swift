import ChatKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct NotificationSoundActions {
    public let customSounds: [NotificationSound]
    public let importFile: (URL) throws -> NotificationSound
    public let preview: (NotificationSound) -> Void

    public init(
        customSounds: [NotificationSound] = [],
        importFile: @escaping (URL) throws -> NotificationSound,
        preview: @escaping (NotificationSound) -> Void
    ) {
        self.customSounds = customSounds
        self.importFile = importFile
        self.preview = preview
    }
}

public extension EnvironmentValues {
    @Entry var notificationSoundActions: NotificationSoundActions?
}

/// The native ringtone menu pattern, with inheritance for every lower level.
struct NotificationSoundPicker: View {
    let value: NotificationSound?
    let inherited: NotificationSound
    var allowsInheritance = true
    let update: (NotificationSound?) -> Void
    @Environment(\.notificationSoundActions) private var actions
    @State private var choosing = false
    @Binding var notice: String?

    init(
        value: NotificationSound?, inherited: NotificationSound,
        allowsInheritance: Bool = true, notice: Binding<String?>,
        update: @escaping (NotificationSound?) -> Void
    ) {
        self.value = value
        self.inherited = inherited
        self.allowsInheritance = allowsInheritance
        self.update = update
        _notice = notice
    }

    private enum Item: Hashable {
        case inherit, kibble, system, custom(NotificationSound), choose
    }

    var body: some View {
        if let actions {
            Picker("Notification Sound", selection: Binding(
                get: { selection },
                set: { item in
                    switch item {
                    case .choose: choosing = true
                    case .inherit: update(nil); actions.preview(inherited)
                    case .kibble: update(.kibble); actions.preview(.kibble)
                    case .system: update(.system); actions.preview(.system)
                    case let .custom(sound): update(sound); actions.preview(sound)
                    }
                }
            )) {
                if allowsInheritance {
                    Text("Default (\(inherited.name))").tag(Item.inherit)
                }
                Text("Kibble").tag(Item.kibble)
                Text("System Default").tag(Item.system)
                ForEach(customChoices(actions), id: \.id) { sound in
                    Text(sound.name).tag(Item.custom(sound))
                }
                Divider()
                Text("Select Audio File…").tag(Item.choose)
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
                do {
                    let file = try result.get()
                    let scoped = file.startAccessingSecurityScopedResource()
                    defer {
                        if scoped {
                            file.stopAccessingSecurityScopedResource()
                        }
                    }
                    let sound = try actions.importFile(file)
                    update(sound)
                    actions.preview(sound)
                    notice = nil
                } catch {
                    // Cancel leaves the menu on the existing sound.
                    if (error as NSError).code != NSUserCancelledError {
                        notice = error.localizedDescription
                    }
                }
            }
        }
    }

    private func customChoices(_ actions: NotificationSoundActions) -> [NotificationSound] {
        var choices = actions.customSounds
        if let value, value != .kibble, value != .system,
           !choices.contains(where: { $0.id == value.id }) {
            choices.insert(value, at: 0)
        }
        return choices
    }

    private var selection: Item {
        guard let value else { return allowsInheritance ? .inherit : .kibble }
        if value == .kibble {
            return .kibble
        }
        if value == .system {
            return .system
        }
        return .custom(value)
    }
}

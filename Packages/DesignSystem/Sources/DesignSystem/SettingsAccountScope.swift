import SwiftUI

/// An account the settings panes can be pinned to.
public struct SettingsAccountChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One account's settings pane with, while several accounts are connected, a
/// picker naming the account being edited. The host pins the choice for as
/// long as Settings is open, so a change of account in the main window never
/// moves a pane underneath a click.
public struct SettingsAccountScope<Content: View>: View {
    private let choices: [SettingsAccountChoice]
    @Binding private var selection: String?
    /// `false` while the chosen account is not running: its settings wait for it.
    private let isAvailable: Bool
    private let content: Content

    public init(
        choices: [SettingsAccountChoice], selection: Binding<String?>, isAvailable: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.choices = choices
        _selection = selection
        self.isAvailable = isAvailable
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if choices.count > 1 {
                Picker("Account", selection: $selection) {
                    ForEach(choices) { choice in
                        Text(choice.label).tag(Optional(choice.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.top, 16)
                .padding(.bottom, 4)
            }
            if isAvailable {
                content
            } else {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("\(label)'s settings can be changed while it is connected.")
                }
                .frame(width: 560, height: 300)
            }
        }
    }

    private var label: String {
        choices.first { $0.id == selection }?.label ?? "This account"
    }
}

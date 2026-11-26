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
    private let showsHeader: Bool
    private let content: Content

    public init(
        choices: [SettingsAccountChoice], selection: Binding<String?>, isAvailable: Bool,
        showsHeader: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.choices = choices
        _selection = selection
        self.isAvailable = isAvailable
        self.showsHeader = showsHeader
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsHeader || !isAvailable {
                SettingsScopeHeader {}
            }
            if isAvailable {
                content.id(selection)
            } else {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("\(label)'s settings can be changed while it is connected.")
                }
                .frame(width: 560, height: 300)
            }
        }
        .environment(\.settingsAccountScope, SettingsAccountScopeState(
            choices: choices, selection: $selection
        ))
    }

    private var label: String {
        choices.first { $0.id == selection }?.label ?? "This account"
    }
}

struct SettingsAccountScopeState {
    let choices: [SettingsAccountChoice]
    let selection: Binding<String?>
}

extension EnvironmentValues {
    @Entry var settingsAccountScope: SettingsAccountScopeState?
}

/// Navigation and account scope share the same row above the form.
struct SettingsScopeHeader<Leading: View, Trailing: View>: View {
    @Environment(\.settingsAccountScope) private var scope
    private let showsNavigation: Bool
    private let leading: Leading
    private let trailing: Trailing

    init(
        showsNavigation: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.showsNavigation = showsNavigation
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if showsNavigation || scope?.choices.isEmpty == false {
            HStack(spacing: 12) {
                leading
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let scope, !scope.choices.isEmpty {
                    Picker("Account", selection: scope.selection) {
                        Text("Global").tag(String?.none)
                        Divider()
                        ForEach(scope.choices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .layoutPriority(1)
                }
                trailing
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 28)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

extension SettingsScopeHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() })
    }
}

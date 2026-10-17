import SwiftUI

/// Whether Kibble may see that a Focus is on.
public enum CallFocusAccess: Equatable, Sendable {
    case notDetermined, allowed, denied
}

public struct CallSettingsState: Equatable, Sendable {
    public var showsPanel: Bool
    public var rings: Bool
    public var focus: CallFocusAccess
    public var closesFinishedCalls: Bool

    public init(showsPanel: Bool, rings: Bool, focus: CallFocusAccess, closesFinishedCalls: Bool) {
        self.showsPanel = showsPanel
        self.rings = rings
        self.focus = focus
        self.closesFinishedCalls = closesFinishedCalls
    }
}

@MainActor
public struct CallSettingsActions {
    public var setShowsPanel: (Bool) -> Void
    public var setRings: (Bool) -> Void
    public var allowFocus: () -> Void
    public var openFocusSettings: () -> Void
    public var setClosesFinishedCalls: (Bool) -> Void

    public init(
        setShowsPanel: @escaping (Bool) -> Void, setRings: @escaping (Bool) -> Void,
        allowFocus: @escaping () -> Void, openFocusSettings: @escaping () -> Void,
        setClosesFinishedCalls: @escaping (Bool) -> Void
    ) {
        self.setShowsPanel = setShowsPanel
        self.setRings = setRings
        self.allowFocus = allowFocus
        self.openFocusSettings = openFocusSettings
        self.setClosesFinishedCalls = setClosesFinishedCalls
    }
}

/// Settings › Calls: how an incoming call reaches this Mac, what the call
/// window does when a call ends, and call sign-in. Device-local, since it
/// depends on this Mac's permissions.
public struct CallSettingsPane: View {
    private let state: CallSettingsState
    private let actions: CallSettingsActions
    private let setUpCalls: (() -> Void)?

    /// `setUpCalls` is offered only while the host can repair call sign-in.
    public init(state: CallSettingsState, actions: CallSettingsActions, setUpCalls: (() -> Void)? = nil) {
        self.state = state
        self.actions = actions
        self.setUpCalls = setUpCalls
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    "Show incoming calls in a floating panel",
                    isOn: Binding(get: { state.showsPanel }, set: actions.setShowsPanel)
                )
                Toggle("Ring", isOn: Binding(get: { state.rings }, set: actions.setRings))
                    .disabled(!state.showsPanel)
                LabeledContent("Focus") { focus }
            } header: {
                Text("Incoming Calls")
            } footer: {
                Text("The panel appears in the top-right corner over any app, without switching to Kibble, "
                    + "and rings when the conversation's notifications play a sound. During a Focus, while a "
                    + "display is mirrored, or when the conversation's notifications only go to Notification "
                    + "Center, Kibble sends its notification instead and macOS decides whether it appears.")
            }
            Section {
                Toggle(
                    "Close the call window when a call ends",
                    isOn: Binding(get: { state.closesFinishedCalls }, set: actions.setClosesFinishedCalls)
                )
            } header: {
                Text("Call Window")
            } footer: {
                Text("The window closes a few seconds after the call ends, and waits while the pointer is "
                    + "over it. A call that failed stays open so you can read why.")
            }
            if let setUpCalls {
                Section {
                    Button("Set Up Calls…", action: setUpCalls)
                } footer: {
                    Text("Sign in for calls again while keeping Chat signed in.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var focus: some View {
        switch state.focus {
        case .notDetermined:
            Button("Allow…", action: actions.allowFocus)
        case .allowed:
            Label("Kibble can see when a Focus is on", systemImage: "checkmark.circle.fill")
                .labelStyle(CallSettingsStatusStyle(tint: .green))
        case .denied:
            HStack(spacing: 8) {
                Label("Not allowed", systemImage: "xmark.circle.fill")
                    .labelStyle(CallSettingsStatusStyle(tint: .secondary))
                Button("Open System Settings", action: actions.openFocusSettings)
            }
        }
    }
}

/// A colored status glyph beside secondary text, as System Settings shows a
/// permission's state.
private struct CallSettingsStatusStyle<Tint: ShapeStyle>: LabelStyle {
    let tint: Tint

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

/// Whether Kibble may see that a Focus is on.
public enum CallFocusAccess: Equatable, Sendable {
    case notDetermined, allowed, denied
}

/// What an incoming call rings with: Kibble's own sound, or the audio file
/// the person last chose.
public enum CallRingtone: Hashable, Sendable {
    case kibble
    case kibbleAlt
    case custom
}

public struct CallSettingsState: Equatable, Sendable {
    public var showsPanel: Bool
    public var rings: Bool
    public var focus: CallFocusAccess
    public var closesFinishedCalls: Bool
    public var ringtone: CallRingtone
    /// The chosen file's name, offered in the menu beside Kibble's own;
    /// `nil` until one is chosen.
    public var customRingtoneName: String?
    /// Why the last chosen file could not be used, drawn first in the
    /// section's footer.
    public var ringtoneNotice: String?

    public init(
        showsPanel: Bool, rings: Bool, focus: CallFocusAccess, closesFinishedCalls: Bool,
        ringtone: CallRingtone = .kibble, customRingtoneName: String? = nil, ringtoneNotice: String? = nil
    ) {
        self.showsPanel = showsPanel
        self.rings = rings
        self.focus = focus
        self.closesFinishedCalls = closesFinishedCalls
        self.ringtone = ringtone
        self.customRingtoneName = customRingtoneName
        self.ringtoneNotice = ringtoneNotice
    }
}

@MainActor
public struct CallSettingsActions {
    public var setShowsPanel: (Bool) -> Void
    public var setRings: (Bool) -> Void
    public var allowFocus: () -> Void
    public var openFocusSettings: () -> Void
    public var setClosesFinishedCalls: (Bool) -> Void
    /// Keeps the choice; the host plays it once, as a preview.
    public var setRingtone: (CallRingtone) -> Void
    /// Opens a file picker. The picker and the copy Kibble keeps are the
    /// host's; this pane only offers the choice.
    public var chooseRingtoneFile: () -> Void

    public init(
        setShowsPanel: @escaping (Bool) -> Void, setRings: @escaping (Bool) -> Void,
        allowFocus: @escaping () -> Void, openFocusSettings: @escaping () -> Void,
        setClosesFinishedCalls: @escaping (Bool) -> Void,
        setRingtone: @escaping (CallRingtone) -> Void, chooseRingtoneFile: @escaping () -> Void
    ) {
        self.setShowsPanel = setShowsPanel
        self.setRings = setRings
        self.allowFocus = allowFocus
        self.openFocusSettings = openFocusSettings
        self.setClosesFinishedCalls = setClosesFinishedCalls
        self.setRingtone = setRingtone
        self.chooseRingtoneFile = chooseRingtoneFile
    }
}

/// Settings › Calls: how an incoming call reaches this Mac, what the call
/// window does when a call ends, and call sign-in. Device-local, since it
/// depends on this Mac's permissions.
public struct CallSettingsPane: View {
    private let reset: (() -> Void)?
    private let resetMessage: String
    private let state: CallSettingsState
    private let actions: CallSettingsActions
    private let setUpCalls: (() -> Void)?

    /// `setUpCalls` is offered only while the host can repair call sign-in.
    public init(
        state: CallSettingsState,
        actions: CallSettingsActions,
        setUpCalls: (() -> Void)? = nil,
        reset: (() -> Void)? = nil,
        resetMessage: String = "Reset these settings to their defaults? This cannot be undone."
    ) {
        self.state = state
        self.actions = actions
        self.setUpCalls = setUpCalls
        self.reset = reset
        self.resetMessage = resetMessage
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
                Picker("Ringtone", selection: ringtoneSelection) {
                    Text("Kibble").tag(RingtoneMenuItem.kibble)
                    Text("Kibble Alternate").tag(RingtoneMenuItem.kibbleAlt)
                    if let name = state.customRingtoneName {
                        Text(name).tag(RingtoneMenuItem.custom)
                    }
                    Divider()
                    Text("Select Audio File…").tag(RingtoneMenuItem.chooseFile)
                }
                .disabled(!state.showsPanel || !state.rings)
                LabeledContent("Focus") { focus }
            } header: {
                Text("Incoming Calls")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let notice = state.ringtoneNotice {
                        Text(notice)
                    }
                    Text(incomingCallsFooter)
                }
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
                    + "over it. A call that failed stays open so you can read why. The microphone, speaker "
                    + "and camera you choose in a call are used for the next one while they’re connected.")
            }
            if let setUpCalls {
                Section {
                    Button("Set Up Calls…", action: setUpCalls)
                } footer: {
                    Text("Sign in for calls again while keeping Chat signed in.")
                }
            }
            if let reset {
                Section {
                    SettingsResetButton(message: resetMessage, action: reset)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Split from the `Text` call so the lines stay under lint's 110-column
    /// limit inside the footer's stack.
    private let incomingCallsFooter = "The panel appears in the top-right corner over any app, without "
        + "switching to Kibble, and rings when the conversation's notifications play a sound. During a "
        + "Focus, while a display is mirrored, or when the conversation's notifications only go to "
        + "Notification Center, Kibble sends its notification instead and macOS decides whether it appears."

    private var ringtoneSelection: Binding<RingtoneMenuItem> {
        Binding(
            get: {
                switch state.ringtone {
                case .kibble: .kibble
                case .kibbleAlt: .kibbleAlt
                case .custom: state.customRingtoneName != nil ? .custom : .kibble
                }
            },
            set: { item in
                switch item {
                case .kibble:
                    actions.setRingtone(.kibble)
                case .kibbleAlt:
                    actions.setRingtone(.kibbleAlt)
                case .custom:
                    actions.setRingtone(.custom)
                case .chooseFile:
                    actions.chooseRingtoneFile()
                }
            }
        )
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

/// The ringtone menu's rows: the two sounds, and the row that picks a file.
private enum RingtoneMenuItem: Hashable {
    case kibble
    case kibbleAlt
    case custom
    case chooseFile
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

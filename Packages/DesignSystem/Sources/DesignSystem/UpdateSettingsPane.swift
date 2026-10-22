import Foundation
import SwiftUI

/// How often Kibble checks for an update on its own, apart from the check
/// at launch.
public enum UpdateFrequency: String, CaseIterable, Sendable {
    case never
    case hourly
    case daily
    case weekly

    /// Menu items, so in title case.
    var title: String {
        switch self {
        case .never: "Never"
        case .hourly: "Every Hour"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        }
    }
}

/// Values in, callbacks out - the `DownloadSettingsState` pattern, for
/// Settings › Updates. The updater itself is the host's and never seen here.
public struct UpdateSettingsState: Equatable, Sendable {
    /// The running build's version, e.g. "2026.41.1".
    public var version: String
    /// `false` in a development build, which never starts an updater.
    public var isEnabled: Bool
    /// Whether Check Now can run: an updater that started and is not
    /// already checking.
    public var canCheck: Bool
    public var lastChecked: Date?
    /// One quiet check each time Kibble starts, apart from the schedule.
    public var checksAtLaunch: Bool
    public var frequency: UpdateFrequency
    public var automaticallyInstalls: Bool
    /// A one-line diagnostic, e.g. an updater that could not start.
    public var notice: String?

    public init(
        version: String,
        isEnabled: Bool,
        canCheck: Bool,
        lastChecked: Date?,
        checksAtLaunch: Bool,
        frequency: UpdateFrequency,
        automaticallyInstalls: Bool,
        notice: String? = nil
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.canCheck = canCheck
        self.lastChecked = lastChecked
        self.checksAtLaunch = checksAtLaunch
        self.frequency = frequency
        self.automaticallyInstalls = automaticallyInstalls
        self.notice = notice
    }

    var lastCheckedText: String {
        lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }

    /// Automatic install only means something while Kibble checks on its
    /// own schedule; the choice is kept under Never.
    var offersAutomaticInstall: Bool {
        isEnabled && frequency != .never
    }

    var shownNotice: String? {
        isEnabled ? notice : "Updates are off in development builds."
    }
}

@MainActor
public struct UpdateSettingsActions {
    public var checkNow: () -> Void
    public var setChecksAtLaunch: (Bool) -> Void
    public var setFrequency: (UpdateFrequency) -> Void
    public var setAutomaticallyInstalls: (Bool) -> Void

    public init(
        checkNow: @escaping () -> Void,
        setChecksAtLaunch: @escaping (Bool) -> Void,
        setFrequency: @escaping (UpdateFrequency) -> Void,
        setAutomaticallyInstalls: @escaping (Bool) -> Void
    ) {
        self.checkNow = checkNow
        self.setChecksAtLaunch = setChecksAtLaunch
        self.setFrequency = setFrequency
        self.setAutomaticallyInstalls = setAutomaticallyInstalls
    }
}

/// Settings › Updates: the version, a manual check, and how Kibble checks
/// on its own. The update window itself is the updater's, not this pane's.
public struct UpdateSettingsPane: View {
    private let state: UpdateSettingsState
    private let actions: UpdateSettingsActions

    public init(state: UpdateSettingsState, actions: UpdateSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: state.version)
                LabeledContent("Last checked") {
                    HStack(spacing: 10) {
                        // At its full width: beside the button, a form's value
                        // column cut a date and time short.
                        Text(state.lastCheckedText)
                            .fixedSize()
                        Button("Check Now", action: actions.checkNow)
                            .disabled(!state.canCheck)
                    }
                }
            } footer: {
                if let notice = state.shownNotice {
                    Text(notice)
                }
            }
            Section {
                Toggle("Check for updates at launch", isOn: Binding(
                    get: { state.checksAtLaunch },
                    set: { actions.setChecksAtLaunch($0) }
                ))
                .disabled(!state.isEnabled)
                Picker("Check automatically", selection: Binding(
                    get: { state.frequency },
                    set: { actions.setFrequency($0) }
                )) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!state.isEnabled)
                Toggle("Download and install automatically", isOn: Binding(
                    get: { state.automaticallyInstalls },
                    set: { actions.setAutomaticallyInstalls($0) }
                ))
                .disabled(!state.offersAutomaticInstall)
            } footer: {
                Text("An update downloaded automatically is installed when you quit Kibble.")
            }
        }
        .formStyle(.grouped)
    }
}

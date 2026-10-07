import Foundation
import SwiftUI

/// How often Kibble checks for an update on its own.
public enum UpdateFrequency: String, CaseIterable, Sendable {
    case atLaunch
    case hourly
    case daily

    var title: String {
        switch self {
        case .atLaunch: "At launch"
        case .hourly: "Every hour"
        case .daily: "Every day"
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
    public var automaticallyChecks: Bool
    public var frequency: UpdateFrequency
    public var automaticallyInstalls: Bool
    /// A one-line diagnostic, e.g. an updater that could not start.
    public var notice: String?

    public init(
        version: String,
        isEnabled: Bool,
        canCheck: Bool,
        lastChecked: Date?,
        automaticallyChecks: Bool,
        frequency: UpdateFrequency,
        automaticallyInstalls: Bool,
        notice: String? = nil
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.canCheck = canCheck
        self.lastChecked = lastChecked
        self.automaticallyChecks = automaticallyChecks
        self.frequency = frequency
        self.automaticallyInstalls = automaticallyInstalls
        self.notice = notice
    }

    var lastCheckedText: String {
        lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }

    /// The frequency and automatic install only mean something while
    /// Kibble checks on its own.
    var offersAutomaticOptions: Bool {
        isEnabled && automaticallyChecks
    }

    var shownNotice: String? {
        isEnabled ? notice : "Updates are off in development builds."
    }
}

@MainActor
public struct UpdateSettingsActions {
    public var checkNow: () -> Void
    public var setAutomaticallyChecks: (Bool) -> Void
    public var setFrequency: (UpdateFrequency) -> Void
    public var setAutomaticallyInstalls: (Bool) -> Void

    public init(
        checkNow: @escaping () -> Void,
        setAutomaticallyChecks: @escaping (Bool) -> Void,
        setFrequency: @escaping (UpdateFrequency) -> Void,
        setAutomaticallyInstalls: @escaping (Bool) -> Void
    ) {
        self.checkNow = checkNow
        self.setAutomaticallyChecks = setAutomaticallyChecks
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
                LabeledContent("Last checked", value: state.lastCheckedText)
                Button("Check Now", action: actions.checkNow)
                    .disabled(!state.canCheck)
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { state.automaticallyChecks },
                    set: { actions.setAutomaticallyChecks($0) }
                ))
                .disabled(!state.isEnabled)
                Picker("Check", selection: Binding(
                    get: { state.frequency },
                    set: { actions.setFrequency($0) }
                )) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!state.offersAutomaticOptions)
                Toggle("Download and install automatically", isOn: Binding(
                    get: { state.automaticallyInstalls },
                    set: { actions.setAutomaticallyInstalls($0) }
                ))
                .disabled(!state.offersAutomaticOptions)
            } footer: {
                Text("An update downloaded automatically is installed when you quit Kibble.")
            }
            if let notice = state.shownNotice {
                Text(notice).foregroundStyle(.secondary).font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

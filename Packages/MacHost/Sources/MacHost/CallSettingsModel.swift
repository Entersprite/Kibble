import AppKit
import CoreGraphics
import DesignSystem
import Foundation
import Intents
import Observation

/// Settings › Calls. Device-local: the panel and Focus access belong to this
/// Mac, not to the account, so they live in `UserDefaults` and never sync.
@MainActor
@Observable
public final class CallSettingsModel {
    static let panelKey = "callsShowPanel"
    static let ringKey = "callsRing"
    static let closeKey = "callsCloseFinishedWindow"

    public private(set) var showsPanel: Bool
    public private(set) var rings: Bool
    public private(set) var focus: CallFocusAccess
    public private(set) var closesFinishedCalls: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let focusStatus: any FocusStatusReading

    public convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, focusStatus: SystemFocusStatus())
    }

    init(defaults: UserDefaults, focusStatus: any FocusStatusReading) {
        self.defaults = defaults
        self.focusStatus = focusStatus
        showsPanel = defaults.object(forKey: Self.panelKey) as? Bool ?? true
        rings = defaults.object(forKey: Self.ringKey) as? Bool ?? true
        closesFinishedCalls = defaults.object(forKey: Self.closeKey) as? Bool ?? true
        focus = focusStatus.access
    }

    public var state: CallSettingsState {
        CallSettingsState(
            showsPanel: showsPanel, rings: rings, focus: focus, closesFinishedCalls: closesFinishedCalls
        )
    }

    public var actions: CallSettingsActions {
        CallSettingsActions(
            setShowsPanel: { [weak self] in self?.setShowsPanel($0) },
            setRings: { [weak self] in self?.setRings($0) },
            allowFocus: { [weak self] in self?.allowFocus() },
            openFocusSettings: { Self.openFocusSettings() },
            setClosesFinishedCalls: { [weak self] in self?.setClosesFinishedCalls($0) }
        )
    }

    /// `nil` when Kibble may not see Focus, which the panel treats as off.
    var isFocused: Bool? {
        focusStatus.isFocused
    }

    func setShowsPanel(_ value: Bool) {
        showsPanel = value
        defaults.set(value, forKey: Self.panelKey)
    }

    func setRings(_ value: Bool) {
        rings = value
        defaults.set(value, forKey: Self.ringKey)
    }

    func setClosesFinishedCalls(_ value: Bool) {
        closesFinishedCalls = value
        defaults.set(value, forKey: Self.closeKey)
    }

    /// Asked from Settings only, never while a call is ringing.
    func allowFocus() {
        Task { [weak self, focusStatus] in
            let access = await focusStatus.requestAccess()
            self?.focus = access
        }
    }

    /// Re-read when Settings opens, since the person can change it in System Settings.
    public func refreshFocusAccess() {
        focus = focusStatus.access
    }

    /// Privacy & Security, at its Focus section.
    static let focusSettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Focus"
    )

    static func openFocusSettings() {
        if let focusSettings {
            NSWorkspace.shared.open(focusSettings)
        }
    }
}

@MainActor
protocol FocusStatusReading {
    var access: CallFocusAccess { get }
    var isFocused: Bool? { get }
    func requestAccess() async -> CallFocusAccess
}

/// `INFocusStatusCenter`: whether a Focus is on, once the person allows it.
/// It cannot say whether Kibble is allowed through that Focus, so a known
/// Focus sends the call to the system notification, which macOS filters.
struct SystemFocusStatus: FocusStatusReading {
    var access: CallFocusAccess {
        Self.access(INFocusStatusCenter.default.authorizationStatus)
    }

    var isFocused: Bool? {
        guard access == .allowed else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    func requestAccess() async -> CallFocusAccess {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: Self.access(status))
            }
        }
    }

    static func access(_ status: INFocusStatusAuthorizationStatus) -> CallFocusAccess {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// While a display is mirrored, macOS hides banners by default; a panel would
/// show the caller to whoever watches the mirror.
enum DisplayMirroring {
    static func isActive() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}

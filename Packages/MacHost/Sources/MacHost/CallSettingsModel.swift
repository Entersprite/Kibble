import AppKit
import CoreGraphics
import DesignSystem
import Foundation
import Intents
import Observation
import UniformTypeIdentifiers

/// Settings › Calls. Device-local: the panel and Focus access belong to this
/// Mac, not to the account, so they live in `UserDefaults` and never sync.
@MainActor
@Observable
public final class CallSettingsModel {
    static let panelKey = "callsShowPanel"
    static let ringKey = "callsRing"
    static let closeKey = "callsCloseFinishedWindow"
    static let ringtoneKey = "callsRingtone"
    static let ringtoneNameKey = "callsRingtoneName"
    static let ringtoneFileKey = "callsRingtoneFile"

    public private(set) var showsPanel: Bool
    public private(set) var rings: Bool
    public private(set) var focus: CallFocusAccess
    public private(set) var closesFinishedCalls: Bool
    public private(set) var ringtone: CallRingtone
    public private(set) var customRingtoneName: String?
    public private(set) var ringtoneNotice: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let focusStatus: any FocusStatusReading
    /// Where Kibble keeps its copy of a chosen ringtone; `nil` when the
    /// container cannot be reached, and then only Kibble's own can be used.
    @ObservationIgnored private let ringtoneDirectory: URL?
    /// Plays a sound once. The host's ringer, set once both exist.
    @ObservationIgnored var previewRingtone: (@MainActor (URL) -> Void)?

    public convenience init(defaults: UserDefaults, ringtoneDirectory: URL?) {
        self.init(defaults: defaults, focusStatus: SystemFocusStatus(), ringtoneDirectory: ringtoneDirectory)
    }

    init(defaults: UserDefaults, focusStatus: any FocusStatusReading, ringtoneDirectory: URL? = nil) {
        self.defaults = defaults
        self.focusStatus = focusStatus
        self.ringtoneDirectory = ringtoneDirectory
        showsPanel = defaults.object(forKey: Self.panelKey) as? Bool ?? true
        rings = defaults.object(forKey: Self.ringKey) as? Bool ?? true
        closesFinishedCalls = defaults.object(forKey: Self.closeKey) as? Bool ?? true
        focus = focusStatus.access
        // A copy that is gone (the container was cleared) is forgotten, and
        // Kibble's own rings instead.
        let kept = Self.customFile(in: ringtoneDirectory, defaults: defaults) != nil
        customRingtoneName = kept ? defaults.string(forKey: Self.ringtoneNameKey) : nil
        ringtone = kept && defaults.string(forKey: Self.ringtoneKey) == Self.customValue ? .custom : .kibble
    }

    public var state: CallSettingsState {
        CallSettingsState(
            showsPanel: showsPanel, rings: rings, focus: focus, closesFinishedCalls: closesFinishedCalls,
            ringtone: ringtone, customRingtoneName: customRingtoneName, ringtoneNotice: ringtoneNotice
        )
    }

    public var actions: CallSettingsActions {
        CallSettingsActions(
            setShowsPanel: { [weak self] in self?.setShowsPanel($0) },
            setRings: { [weak self] in self?.setRings($0) },
            allowFocus: { [weak self] in self?.allowFocus() },
            openFocusSettings: { Self.openFocusSettings() },
            setClosesFinishedCalls: { [weak self] in self?.setClosesFinishedCalls($0) },
            setRingtone: { [weak self] in self?.setRingtone($0) },
            chooseRingtoneFile: { [weak self] in self?.chooseRingtoneFile() }
        )
    }

    /// What a call rings with: the chosen file while Kibble's copy is there,
    /// otherwise Kibble's own.
    var ringtoneURL: URL? {
        if ringtone == .custom, let file = customFile {
            return file
        }
        return Ringtone.bundled
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

    func setRingtone(_ value: CallRingtone) {
        guard value == .kibble || customFile != nil else { return }
        ringtone = value
        ringtoneNotice = nil
        defaults.set(value == .custom ? Self.customValue : Self.kibbleValue, forKey: Self.ringtoneKey)
        if let url = ringtoneURL {
            previewRingtone?(url)
        }
    }

    func chooseRingtoneFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a sound of up to \(Int(Ringtone.maximumDuration)) seconds. "
            + "It rings in a loop."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRingtone(from: url)
    }

    /// Keeps a copy of the chosen file, so it still rings after the original
    /// is moved or deleted, and the sandbox needs no lasting access to it.
    /// A file that cannot be used leaves the current ringtone as it was.
    func importRingtone(from source: URL) {
        let file = source.lastPathComponent
        do {
            _ = try Ringtone.decode(source)
        } catch {
            ringtoneNotice = Self.notice(for: error, file: file)
            return
        }
        let previous = customFile
        let fileExtension = source.pathExtension
        let stored = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        guard let ringtoneDirectory else {
            ringtoneNotice = "Kibble couldn't keep a copy of “\(file)”."
            return
        }
        let destination = ringtoneDirectory.appendingPathComponent(stored)
        do {
            try FileManager.default.createDirectory(at: ringtoneDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            ringtoneNotice = "Kibble couldn't keep a copy of “\(file)”."
            return
        }
        defaults.set(stored, forKey: Self.ringtoneFileKey)
        defaults.set(source.deletingPathExtension().lastPathComponent, forKey: Self.ringtoneNameKey)
        defaults.set(Self.customValue, forKey: Self.ringtoneKey)
        if let previous {
            try? FileManager.default.removeItem(at: previous)
        }
        customRingtoneName = source.deletingPathExtension().lastPathComponent
        ringtone = .custom
        ringtoneNotice = nil
        previewRingtone?(destination)
    }

    private static let kibbleValue = "kibble"
    private static let customValue = "custom"

    private var customFile: URL? {
        Self.customFile(in: ringtoneDirectory, defaults: defaults)
    }

    private static func customFile(in directory: URL?, defaults: UserDefaults) -> URL? {
        guard let directory, let stored = defaults.string(forKey: ringtoneFileKey) else { return nil }
        let url = directory.appendingPathComponent(stored)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func notice(for failure: Ringtone.Failure, file: String) -> String {
        switch failure {
        case .unreadable:
            "Kibble can't play “\(file)”. Choose an audio file such as AIFF, WAV, M4A or MP3."
        case .empty:
            "“\(file)” has no sound in it."
        case .tooLong:
            "“\(file)” is longer than \(Int(Ringtone.maximumDuration)) seconds. Choose a shorter sound."
        }
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

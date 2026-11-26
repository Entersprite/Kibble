import Foundation

/// The microphone, speaker and camera last chosen in the call window, which the
/// next call starts with. Device-local, beside the other call settings, and
/// shared by every account: calls on different accounts use this Mac's one set
/// of hardware, so a choice made during one account's call carries to the next
/// call on any account.
///
/// The identifiers are the ones the system keeps across launches, reconnections
/// and restarts: the Core Audio device UID for microphones and speakers (the
/// audio module's own device ID is a per-session object ID, translated by
/// `CallAudioRouting.persistentID`), and `AVCaptureDevice.uniqueID` for cameras.
/// They stay on this Mac; nothing here reaches a call service, a report or
/// another device.
///
/// A saved device that is missing when a call starts stays saved, so it is
/// used again once it is back; meanwhile the call uses the system default.
@MainActor
final class CallDevicePreferences {
    static let microphoneKey = "callsMicrophone"
    static let speakerKey = "callsSpeaker"
    static let cameraKey = "callsCamera"
    static let keys = [microphoneKey, speakerKey, cameraKey]

    /// The app's own preferences, where `CallSettingsModel` keeps the rest.
    static let standard = CallDevicePreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `""` is System Default.
    var microphone: String {
        value(for: Self.microphoneKey)
    }

    /// `""` is System Default.
    var speaker: String {
        value(for: Self.speakerKey)
    }

    /// `""` is the first camera, which is what a call uses without a choice.
    var camera: String {
        value(for: Self.cameraKey)
    }

    func saveAudio(_ id: String, microphone: Bool) {
        save(id, for: microphone ? Self.microphoneKey : Self.speakerKey)
    }

    func saveCamera(_ id: String) {
        save(id, for: Self.cameraKey)
    }

    private func value(for key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }

    private func save(_ id: String, for key: String) {
        if id.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(id, forKey: key)
        }
    }
}

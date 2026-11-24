import DesignSystem
import Foundation
import Observation

/// One local route for the active media engine. A microphone or speaker the
/// person picks is saved in `preferences`, and the next route starts on it when
/// that device is connected; otherwise it starts on System Default.
@MainActor
@Observable
public final class CallAudioDeviceController {
    private var currentDevices: CallAudioDevices?
    @ObservationIgnored private let preferences: CallDevicePreferences?
    @ObservationIgnored private let speakerPlayback: any CallSpeakerPlayback
    @ObservationIgnored private let defaultOutput: @MainActor () -> String?
    private var scope = UUID()
    private var refreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var route: (any CallAudioRouting)?
    private var selectionRevision = 0
    private var selectionFailure: String?
    private var microphoneLevelID = UUID()
    @ObservationIgnored private var readMicrophoneLevel: (@MainActor () async -> Double?)?
    private var speakerTestID: UUID?
    @ObservationIgnored private var speakerTestTask: Task<Void, Never>?
    private var speakerTestFailure: String?

    public var devices: CallAudioDevices? {
        guard var devices = currentDevices else { return nil }
        devices.notice = devices.notice ?? speakerTestFailure
        return devices
    }

    public convenience init() {
        self.init(preferences: nil)
    }

    init(
        preferences: CallDevicePreferences?,
        speakerPlayback: any CallSpeakerPlayback = NativeCallSpeakerPlayback(),
        defaultOutput: @escaping @MainActor () -> String? = NativeCallSpeakerPlayback.defaultOutput
    ) {
        self.preferences = preferences
        self.speakerPlayback = speakerPlayback
        self.defaultOutput = defaultOutput
    }

    var microphoneModeScope: UUID? {
        guard let devices, !devices.isUpdating, !devices.microphones.isEmpty else { return nil }
        return scope
    }

    @discardableResult
    func install(
        _ route: any CallAudioRouting, readMicrophoneLevel: (@MainActor () async -> Double?)? = nil
    ) -> UUID {
        clear()
        self.route = route
        self.readMicrophoneLevel = readMicrophoneLevel
        let scope = scope
        let saved = preferences.map { [($0.microphone, true), ($0.speaker, false)] } ?? []
        refreshTask = Task { [weak self] in
            // Before the first snapshot, so the picker never shows a default
            // that is about to change. A saved device that is missing, or that
            // refuses the switch, leaves System Default with no notice.
            for (persistentID, microphone) in saved where !persistentID.isEmpty {
                _ = await route.restore(persistentID, microphone: microphone)
            }
            while !Task.isCancelled {
                let revision = self?.selectionRevision
                let snapshot = await route.snapshot()
                guard !Task.isCancelled, let self, self.scope == scope else { return }
                if selectionTask == nil, revision == selectionRevision {
                    apply(snapshot)
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        return scope
    }

    func clear(ifCurrent expected: UUID? = nil) {
        if let expected, expected != scope {
            return
        }
        scope = UUID()
        microphoneLevelID = UUID()
        readMicrophoneLevel = nil
        stopSpeakerTest()
        refreshTask?.cancel()
        refreshTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        route = nil
        currentDevices = nil
        selectionFailure = nil
        speakerTestFailure = nil
    }

    public func select(_ id: String, microphone: Bool) {
        guard let route, selectionTask == nil, currentDevices != nil else { return }
        let scope = scope
        selectionRevision += 1
        microphoneLevelID = UUID()
        selectionFailure = nil
        stopSpeakerTest()
        speakerTestFailure = nil
        currentDevices?.isUpdating = true
        selectionTask = Task { [weak self] in
            let succeeded = await route.select(id, microphone: microphone)
            // A device the hardware cannot name lastingly is not kept; the
            // next call then starts on System Default, never on a stale choice.
            let persistentID = succeeded && !id.isEmpty
                ? await route.persistentID(of: id, microphone: microphone) ?? "" : ""
            var snapshot = await route.snapshot()
            guard !Task.isCancelled, let self, self.scope == scope else { return }
            if succeeded {
                preferences?.saveAudio(persistentID, microphone: microphone)
            } else {
                selectionFailure = "Couldn’t switch audio devices. Please choose another device."
                snapshot.notice = selectionFailure
            }
            apply(snapshot)
            selectionTask = nil
        }
    }

    private func apply(_ snapshot: CallAudioDevices) {
        if let currentDevices, currentDevices.microphone != snapshot.microphone ||
            currentDevices.microphones != snapshot.microphones {
            microphoneLevelID = UUID()
        }
        if let currentDevices, currentDevices.speaker != snapshot.speaker ||
            currentDevices.speakers.first(where: { $0.id == currentDevices.speaker }) !=
            snapshot.speakers.first(where: { $0.id == snapshot.speaker }) {
            stopSpeakerTest()
        }
        var snapshot = snapshot
        snapshot.notice = snapshot.notice ?? selectionFailure
        currentDevices = snapshot
    }

    var microphoneLevelScope: UUID? {
        guard microphoneModeScope != nil, readMicrophoneLevel != nil else { return nil }
        return microphoneLevelID
    }

    func microphoneLevel(in expected: UUID) async -> Double? {
        guard !Task.isCancelled, microphoneLevelScope == expected, let readMicrophoneLevel else {
            return nil
        }
        let level = await readMicrophoneLevel()
        guard !Task.isCancelled, microphoneLevelScope == expected,
              let level, level.isFinite, (0 ... 1).contains(level) else { return nil }
        return MicrophoneLevel.normalized(power: Float(level * level))
    }

    var speakerTestScope: UUID? {
        guard let currentDevices, !currentDevices.isUpdating, !currentDevices.speakers.isEmpty else {
            return nil
        }
        return scope
    }

    var isTestingSpeaker: Bool {
        speakerTestID != nil
    }

    func toggleSpeakerTest(in expected: UUID, allowed: @escaping @MainActor () -> Bool) {
        guard speakerTestScope == expected, let route, let selection = currentDevices?.speaker, allowed()
        else { return }
        if isTestingSpeaker {
            stopSpeakerTest()
            return
        }
        speakerTestFailure = nil
        let id = UUID()
        speakerTestID = id
        let defaultOutput = defaultOutput
        speakerTestTask = Task { [weak self] in
            let uid = if selection.isEmpty {
                defaultOutput()
            } else {
                await route.persistentID(of: selection, microphone: false)
            }
            guard let self, speakerTestID == id else { return }
            guard allowed(), speakerTestScope == expected else { stopSpeakerTest(); return }
            playSpeakerTest(device: uid, id: id)
        }
    }

    private func playSpeakerTest(device uid: String?, id: UUID) {
        guard let uid else { finishSpeakerTest(id, success: false); return }
        do {
            try speakerPlayback.play(device: uid) { [weak self] success in
                self?.finishSpeakerTest(id, success: success)
            }
        } catch {
            finishSpeakerTest(id, success: false)
        }
    }

    private func finishSpeakerTest(_ id: UUID, success: Bool) {
        guard speakerTestID == id else { return }
        stopSpeakerTest()
        if !success {
            speakerTestFailure = "Couldn’t play the speaker test."
        }
    }

    private func stopSpeakerTest() {
        guard isTestingSpeaker else { return }
        speakerTestTask?.cancel()
        speakerTestTask = nil
        speakerTestID = nil
        speakerPlayback.stop()
    }
}

protocol CallAudioRouting: Sendable {
    func snapshot() async -> CallAudioDevices
    func select(_ id: String, microphone: Bool) async -> Bool
    /// What to save for a connected device: an identifier that survives
    /// relaunch and reconnection, unlike the picker's. `nil` when unknown.
    func persistentID(of id: String, microphone: Bool) async -> String?
    /// Selects the connected device saved as `persistentID`; `false`, with
    /// nothing changed, when none is connected.
    func restore(_ persistentID: String, microphone: Bool) async -> Bool
}

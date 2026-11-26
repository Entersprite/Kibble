import CoreAudio
import DesignSystem
import Foundation
import Observation

struct CallPreparationAudioCatalog: Equatable {
    var microphones: [CallAudioDevice] = []
    var speakers: [CallAudioDevice] = []
    var defaultMicrophone: String?
    var defaultSpeaker: String?

    static func read() -> Self {
        let system = AudioHardwareSystem.shared
        var catalog = Self(
            defaultMicrophone: try? system.defaultInputDevice?.uid,
            defaultSpeaker: try? system.defaultOutputDevice?.uid
        )
        guard let devices = try? system.devices else { return catalog }
        for device in devices where !CoreAudioDeviceVisibility.isPrivateAggregate(device.id) {
            guard let uid = try? device.uid, !uid.isEmpty, let name = try? device.name,
                  let streams = try? device.streams else { continue }
            let option = CallAudioDevice(id: uid, name: name)
            let directions = streams.compactMap { try? $0.direction }
            if directions.contains(.input), !catalog.microphones.contains(where: { $0.id == uid }) {
                catalog.microphones.append(option)
            }
            if directions.contains(.output), !catalog.speakers.contains(where: { $0.id == uid }) {
                catalog.speakers.append(option)
            }
        }
        catalog.microphones.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        catalog.speakers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return catalog
    }

    func choices(microphone: Bool) -> [CallAudioDevice] {
        microphone ? microphones : speakers
    }

    func availableChoice(_ selection: String, microphone: Bool) -> String {
        choices(microphone: microphone).contains { $0.id == selection } ? selection : ""
    }

    func device(for selection: String, microphone: Bool) -> String? {
        let selected = availableChoice(selection, microphone: microphone)
        return selected.isEmpty ? (microphone ? defaultMicrophone : defaultSpeaker) : selected
    }
}

@MainActor
@Observable
final class CallPreparationDevices {
    private var catalog = CallPreparationAudioCatalog()
    private var microphoneChoice = ""
    private var speakerChoice = ""
    private var cameraChoice = ""
    private(set) var cameras: [CallCameraDevice] = []
    @ObservationIgnored private var changedMicrophone = false
    @ObservationIgnored private var changedSpeaker = false
    @ObservationIgnored private var changedCamera = false
    @ObservationIgnored private var meeting: UUID?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private let preferences: CallDevicePreferences
    @ObservationIgnored private let readAudio: () -> CallPreparationAudioCatalog
    @ObservationIgnored private let readCameras: () -> [CallCameraDevice]

    init(
        preferences: CallDevicePreferences = .standard,
        readAudio: @escaping () -> CallPreparationAudioCatalog = CallPreparationAudioCatalog.read,
        readCameras: @escaping () -> [CallCameraDevice] = NativeCallCameras.choices
    ) {
        self.preferences = preferences
        self.readAudio = readAudio
        self.readCameras = readCameras
    }

    var devices: CallAudioDevices {
        .init(
            microphones: catalog.microphones, speakers: catalog.speakers,
            microphone: catalog.availableChoice(microphoneChoice, microphone: true),
            speaker: catalog.availableChoice(speakerChoice, microphone: false)
        )
    }

    var microphone: String? {
        catalog.device(for: microphoneChoice, microphone: true)
    }

    var speaker: String? {
        catalog.device(for: speakerChoice, microphone: false)
    }

    var selectedCamera: String {
        cameras.contains { $0.id == cameraChoice } ? cameraChoice : ""
    }

    var camera: String? {
        let selected = selectedCamera
        return selected.isEmpty ? cameras.first?.id : selected
    }

    func bind(_ id: UUID?) {
        guard meeting != id else { return }
        refresh?.cancel()
        refresh = nil
        meeting = id
        changedMicrophone = false
        changedSpeaker = false
        changedCamera = false
        guard let id else { return }
        microphoneChoice = preferences.microphone
        speakerChoice = preferences.speaker
        cameraChoice = preferences.camera
        refreshCatalog(for: id)
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refreshCatalog(for: id)
            }
        }
    }

    private func refreshCatalog(for id: UUID) {
        guard meeting == id else { return }
        let next = readAudio()
        if next != catalog {
            catalog = next
        }
        let nextCameras = readCameras()
        if nextCameras != cameras {
            cameras = nextCameras
        }
    }

    func select(_ uid: String, microphone: Bool, for id: UUID) {
        guard meeting == id,
              uid.isEmpty || catalog.availableChoice(uid, microphone: microphone) == uid else { return }
        if microphone {
            microphoneChoice = uid
            changedMicrophone = true
        } else {
            speakerChoice = uid
            changedSpeaker = true
        }
    }

    func saveChoices(for id: UUID) {
        guard meeting == id else { return }
        if changedMicrophone {
            preferences.saveAudio(microphoneChoice, microphone: true)
        }
        if changedSpeaker {
            preferences.saveAudio(speakerChoice, microphone: false)
        }
        if changedCamera {
            preferences.saveCamera(cameraChoice)
        }
        changedMicrophone = false
        changedSpeaker = false
        changedCamera = false
    }

    func selectCamera(_ id: String, for meetingID: UUID) {
        guard meeting == meetingID, id.isEmpty || cameras.contains(where: { $0.id == id }) else { return }
        cameraChoice = id
        changedCamera = true
    }

    isolated deinit {
        refresh?.cancel()
    }
}

import AppKit
import DesignSystem

@MainActor
struct CallPreparationHardware {
    let camera = CallPreparationCamera()
    let audio = CallPreparationAudio()
    let devices = CallPreparationDevices()
}

extension AudioCallWindowHost {
    func retirePreparation() {
        preparation.camera.bind(nil)
        preparation.audio.bind(nil)
        preparation.devices.bind(nil)
    }

    func addPreparation(to actions: inout AudioCallActions, callID: UUID, window: NSWindow) {
        guard var scene = actions.meetingPreparation else {
            retirePreparation()
            return
        }
        preparation.camera.bind(callID)
        preparation.audio.bind(callID)
        preparation.devices.bind(callID)
        updateAudioSelection()
        preparation.camera.configure(device: preparation.devices.camera)
        scene.microphone = CallMeetingPreparationDevices
            .microphoneStatus(hasDevice: preparation.devices.microphone != nil)
        scene.hasSpeaker = preparation.devices.speaker != nil
        scene.camera = CallMeetingPreparationDevices
            .cameraStatus(hasDevice: preparation.devices.camera != nil)
        let available = scene.canCheckDevices
        let canSelect: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.callID == callID && available() && !preparation.camera.isJoining
        }
        let allowed: @MainActor () -> Bool = { [weak window] in
            window?.isKeyWindow == true && canSelect()
        }
        if available() {
            addCamera(to: &scene, id: callID, allowed: allowed, canSelect: canSelect)
            addAudio(to: &scene, id: callID, allowed: allowed, canSelect: canSelect)
        } else {
            preparation.camera.hide()
            preparation.audio.stop()
        }
        scene.isJoining = preparation.camera.isJoining
        let join = scene.join
        scene.join = { [weak self] in
            guard let self, self.callID == callID else { return }
            preparation.camera.join(callID, after: preparation.audio.stop()) { [weak self] in
                if available() {
                    self?.preparation.devices.saveChoices(for: callID)
                }
                join()
            }
        }
        actions.meetingPreparation = scene
    }

    private func addCamera(
        to scene: inout CallMeetingPreparation,
        id: UUID,
        allowed: @escaping @MainActor () -> Bool,
        canSelect: @escaping @MainActor () -> Bool
    ) {
        scene.cameraSelection = .init(
            devices: preparation.devices.cameras, selection: preparation.devices.selectedCamera,
            select: { [weak self] choice in
                guard let self, canSelect() else { return }
                preparation.devices.selectCamera(choice, for: id)
                preparation.camera.configure(device: preparation.devices.camera, resumePreview: allowed)
            }
        )
        if scene.camera == .ready || scene.camera == .needsPermission {
            scene.cameraPreview = .init(
                content: preparation.camera.view, isStarting: preparation.camera.isStarting,
                notice: preparation.camera.notice, toggle: { [weak self] in
                    self?.preparation.camera.toggle(in: id, mayCapture: allowed)
                }
            )
        } else {
            preparation.camera.hide()
        }
    }

    private func addAudio(
        to scene: inout CallMeetingPreparation,
        id: UUID,
        allowed: @escaping @MainActor () -> Bool,
        canSelect: @escaping @MainActor () -> Bool
    ) {
        scene.audioSelection = .init(
            devices: preparation.devices.devices,
            selectMicrophone: { [weak self] uid in self?.selectAudio(
                uid,
                microphone: true,
                id: id,
                allowed: canSelect
            ) },
            selectSpeaker: { [weak self] uid in self?.selectAudio(
                uid,
                microphone: false,
                id: id,
                allowed: canSelect
            ) }
        )
        let canTestMic = scene.microphone == .ready || scene.microphone == .needsPermission
        let microphone: (() -> Void)? = canTestMic ? { [weak self] in
            self?.preparation.audio.toggleMicrophone(in: id, allowed: allowed)
        } : nil
        let speaker: (() -> Void)? = scene.hasSpeaker ? { [weak self] in
            self?.preparation.audio.toggleSpeaker(in: id, allowed: allowed)
        } : nil
        scene.audioChecks = .init(
            microphone: preparation.audio.microphone, toggleMicrophone: microphone,
            isPlaying: preparation.audio.isPlaying, toggleSpeaker: speaker, notice: preparation.audio.notice
        )
    }

    private func selectAudio(_ uid: String, microphone: Bool, id: UUID, allowed: @MainActor () -> Bool) {
        guard allowed() else { return }
        preparation.devices.select(uid, microphone: microphone, for: id)
        updateAudioSelection()
    }

    private func updateAudioSelection() {
        preparation.audio.configure(
            microphone: preparation.devices.microphone,
            speaker: preparation.devices.speaker
        )
    }
}

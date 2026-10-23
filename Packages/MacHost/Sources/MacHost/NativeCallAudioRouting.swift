import CoreAudio
import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC

/// WebRTC serializes its ADM calls internally. This extra queue keeps device
/// discovery and route changes off the UI thread and orders shutdown after them.
final class NativeCallAudioRouting: CallAudioRouting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Kibble.call-audio-devices")
    private var hardware: (any CallAudioHardware)?
    private var microphone = ""
    private var speaker = ""
    private var notice: String?

    convenience init(factory: LKRTCPeerConnectionFactory) {
        self.init(hardware: WebRTCCallAudioHardware(factory: factory))
    }

    init(hardware: any CallAudioHardware) {
        self.hardware = hardware
    }

    func close() {
        queue.sync { hardware = nil }
    }

    func snapshot() async -> CallAudioDevices {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let hardware = self.hardware else {
                    continuation.resume(returning: CallAudioDevices(microphones: [], speakers: []))
                    return
                }
                var inputs = hardware.devices(microphone: true)
                var outputs = hardware.devices(microphone: false)
                if !self.microphone.isEmpty, !inputs.contains(where: { $0.id == self.microphone }) {
                    if hardware.select("", microphone: true) {
                        self.microphone = ""
                        self.notice = "Microphone disconnected. Using System Default."
                    } else {
                        inputs.append(CallAudioDevice(id: self.microphone, name: "Unavailable microphone"))
                        self.notice = "Microphone unavailable. Choose another device."
                    }
                }
                if !self.speaker.isEmpty, !outputs.contains(where: { $0.id == self.speaker }) {
                    if hardware.select("", microphone: false) {
                        self.speaker = ""
                        self.notice = "Speaker disconnected. Using System Default."
                    } else {
                        outputs.append(CallAudioDevice(id: self.speaker, name: "Unavailable speaker"))
                        self.notice = "Speaker unavailable. Choose another device."
                    }
                }
                continuation.resume(returning: CallAudioDevices(
                    microphones: inputs, speakers: outputs,
                    microphone: self.microphone, speaker: self.speaker, notice: self.notice
                ))
            }
        }
    }

    func select(_ id: String, microphone: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.selectOnQueue(id, microphone: microphone))
            }
        }
    }

    func persistentID(of id: String, microphone: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let hardware = self.hardware,
                      hardware.devices(microphone: microphone).contains(where: { $0.id == id })
                else { continuation.resume(returning: nil); return }
                continuation.resume(returning: hardware.persistentID(of: id))
            }
        }
    }

    func restore(_ persistentID: String, microphone: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let hardware = self.hardware, !persistentID.isEmpty, let device = hardware
                    .devices(microphone: microphone)
                    .first(where: { hardware.persistentID(of: $0.id) == persistentID })
                else { continuation.resume(returning: false); return }
                continuation.resume(returning: self.selectOnQueue(device.id, microphone: microphone))
            }
        }
    }

    private func selectOnQueue(_ id: String, microphone: Bool) -> Bool {
        guard let hardware else { return false }
        let devices = hardware.devices(microphone: microphone)
        guard id.isEmpty || devices.contains(where: { $0.id == id }) else { return false }
        let success = hardware.select(id, microphone: microphone)
        if success {
            notice = nil
            if microphone {
                self.microphone = id
            } else {
                speaker = id
            }
        }
        return success
    }
}

/// All methods are used exclusively on the route's serial queue.
protocol CallAudioHardware: Sendable {
    func devices(microphone: Bool) -> [CallAudioDevice]
    func select(_ id: String, microphone: Bool) -> Bool
    /// The device's name across relaunches, reconnections and restarts, or
    /// `nil` when the hardware cannot give one. `devices` IDs need not last.
    func persistentID(of id: String) -> String?
}

private final class WebRTCCallAudioHardware: CallAudioHardware, @unchecked Sendable {
    // The module's worker belongs to its factory, which must outlive every
    // queued device operation, including a peer-creation failure.
    private let factory: LKRTCPeerConnectionFactory
    private var module: LKRTCAudioDeviceModule {
        factory.audioDeviceModule
    }

    init(factory: LKRTCPeerConnectionFactory) {
        self.factory = factory
    }

    func devices(microphone: Bool) -> [CallAudioDevice] {
        (microphone ? module.inputDevices : module.outputDevices).filter { !$0.isDefault }
            .map { CallAudioDevice(id: $0.deviceId, name: $0.name) }
    }

    func select(_ id: String, microphone: Bool) -> Bool {
        let devices = microphone ? module.inputDevices : module.outputDevices
        let device = id.isEmpty ? LKRTCIODevice.defaultDevice(with: microphone ? .input : .output)
            : devices.first { $0.deviceId == id }
        guard let device else { return false }
        return microphone ? module.trySetInputDevice(device) : module.trySetOutputDevice(device)
    }

    /// The audio module names a device by its Core Audio object ID, which the
    /// system may reassign after a reconnection or restart. The device UID is
    /// the identifier Core Audio keeps.
    func persistentID(of id: String) -> String? {
        guard let object = AudioObjectID(id) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }
}

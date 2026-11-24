import AVFoundation
import DesignSystem
@preconcurrency import LiveKitWebRTC

enum NativeCallCameras {
    static func choices() -> [CallCameraDevice] {
        LKRTCCameraVideoCapturer.captureDevices().map {
            CallCameraDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    static func device(for id: String) -> AVCaptureDevice? {
        let devices = LKRTCCameraVideoCapturer.captureDevices()
        return id.isEmpty ? devices.first : devices.first { $0.uniqueID == id }
    }
}

import LocalBridgeBackend
import OSLog

extension ProviderDiagnostics {
    static var native: ProviderDiagnostics {
        let log = Logger(subsystem: "com.entersprite.kibble", category: "MeetingMetadata")
        return ProviderDiagnostics { event in
            switch event {
            case let .meetingMetadata(visible, ready, queued):
                log.notice("Meeting metadata: visible=\(visible) ready=\(ready) queued=\(queued)")
            case let .meetingDetail(supported):
                log.notice("Meeting detail metadata: supported=\(supported)")
            case .meetingDetailFailed:
                log.notice("Meeting detail metadata: request failed")
            case .meetingCacheWriteFailed:
                log.error("Meeting metadata cache could not be saved")
            }
        }
    }
}

import OSLog
import ServiceClient

extension ServiceClientDiagnostics {
    static var native: ServiceClientDiagnostics {
        let log = Logger(subsystem: "com.entersprite.kibble", category: "pins")
        return ServiceClientDiagnostics { event in
            switch event {
            case let .pinReadFinished(count):
                log.notice("Pin refresh completed: count=\(count)")
            case let .pinReadFailed(stage, failure):
                log
                    .error(
                        "Pin read failed: stage=\(stage, privacy: .public) kind=\(failure, privacy: .public)"
                    )
            case let .mediaReadFailed(failure):
                log.error("Media read failed: kind=\(failure, privacy: .public)")
            }
        }
    }
}

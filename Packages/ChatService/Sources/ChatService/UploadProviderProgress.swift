import Synchronization

/// One bounded latest value per upload. Provider callbacks never enqueue tasks
/// or retain an account runtime, and regressions/invalid byte counts are ignored.
final class UploadProviderProgress: Sendable {
    private let value = Mutex(0)

    func record(_ count: Int, maximum: Int) {
        guard count >= 0, count <= maximum else { return }
        value.withLock { $0 = max($0, count) }
    }

    var bytesSent: Int {
        value.withLock { $0 }
    }
}

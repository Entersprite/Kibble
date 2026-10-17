import AppKit
import Foundation
import LocalBridgeBackend

/// Owns only system sleep/wake observations, for the lifetime of one native peer.
@MainActor
final class CallMediaRecoveryMonitor {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<CallMediaEvent>.Continuation?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func start(receive: @escaping @Sendable (CallMediaEvent) async -> Void) {
        guard task == nil else { return }
        let (events, continuation) = AsyncStream.makeStream(of: CallMediaEvent.self)
        self.continuation = continuation
        observers = [
            (NSWorkspace.willSleepNotification, CallMediaEvent.suspended),
            (NSWorkspace.didWakeNotification, CallMediaEvent.resumed)
        ].map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                continuation.yield(event)
            }
        }
        task = Task {
            for await event in events {
                guard !Task.isCancelled else { return }
                await receive(event)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }
}

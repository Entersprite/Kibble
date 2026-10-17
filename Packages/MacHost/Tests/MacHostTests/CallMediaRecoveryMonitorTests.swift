import AppKit
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
struct CallMediaRecoveryMonitorTests {
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        try #require(await condition())
    }

    @Test func sleepWakeDeliveryIsScopedAndFreshAfterRestart() async throws {
        let center = NotificationCenter()
        let monitor = CallMediaRecoveryMonitor(center: center)
        let first = RecoveryEvents()
        monitor.start { await first.receive($0) }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await wait { await first.values.count == 2 }
        #expect(await first.values == ["suspended", "resumed"])
        monitor.stop()
        let second = RecoveryEvents()
        monitor.start { await second.receive($0) }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await wait { await second.values.count == 2 }
        #expect(await first.values.count == 2)
        #expect(await second.values == ["suspended", "resumed"])
        monitor.stop()
    }
}

private actor RecoveryEvents {
    var values: [String] = []
    func receive(_ event: CallMediaEvent) {
        switch event {
        case .suspended: values.append("suspended")
        case .resumed: values.append("resumed")
        default: values.append("unexpected")
        }
    }
}

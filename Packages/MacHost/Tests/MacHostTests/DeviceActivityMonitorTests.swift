import AppKit
import Foundation
import Testing
@testable import MacHost

/// Whether this Mac is in use (active-presence spec §5): awake, displays on,
/// unlocked, and this login session in front.
@MainActor
@Suite(.serialized)
struct DeviceActivityMonitorTests {
    @Test func inUseOnlyWithNothingSet() {
        var state = DeviceActivityState()
        #expect(state.isInUse)
        let pairs: [(DeviceActivityState.Signal, DeviceActivityState.Signal)] = [
            (.systemSlept, .systemWoke), (.displaysSlept, .displaysWoke),
            (.locked, .unlocked), (.sessionLeft, .sessionReturned)
        ]
        for (away, back) in pairs {
            state.apply(away)
            #expect(!state.isInUse)
            state.apply(back)
            #expect(state.isInUse)
        }
    }

    /// Waking does not unlock: the lock screen is not the person.
    @Test func wakingIntoTheLockScreenIsNotInUse() {
        var state = DeviceActivityState()
        state.apply(.locked)
        state.apply(.systemSlept)
        state.apply(.systemWoke)
        #expect(!state.isInUse)
        state.apply(.unlocked)
        #expect(state.isInUse)
    }

    @Test func eachNotificationIsItsSignal() {
        let names: [(Notification.Name, DeviceActivityState.Signal)] = [
            (NSWorkspace.willSleepNotification, .systemSlept),
            (NSWorkspace.didWakeNotification, .systemWoke),
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.screensDidWakeNotification, .displaysWoke),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionLeft),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionReturned),
            (Notification.Name("com.apple.screenIsLocked"), .locked),
            (Notification.Name("com.apple.screenIsUnlocked"), .unlocked)
        ]
        for (name, signal) in names {
            #expect(DeviceActivityMonitor.signals[name] == signal)
        }
        #expect(DeviceActivityMonitor.signals.count == names.count)
    }

    /// Only a change in the answer is sent: displays sleeping behind the lock
    /// screen says nothing new.
    @Test func theStreamSaysOnlyWhatChanges() async {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let monitor = DeviceActivityMonitor(workspace: workspace, distributed: distributed)
        let consumer = Consumer(monitor.changes)

        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(await consumer.next() == false)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(await consumer.next() == true)
    }

    /// One fresh stream per access, as `AppActivityMonitor`'s: ending one
    /// leaves the other listening (`findings.md` §25.10).
    @Test func twoStreamsAreIndependent() async {
        let workspace = NotificationCenter()
        let monitor = DeviceActivityMonitor(workspace: workspace, distributed: NotificationCenter())
        let first = Consumer(monitor.changes)
        var second: Consumer? = Consumer(monitor.changes)
        second = nil
        #expect(second == nil)

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await first.next() == false)
    }
}

/// One iterator, read on the main actor, as `AppActivityMonitorTests`'
/// `IteratorBox` is: the class itself is not isolated, its read is.
private final class Consumer {
    private var iterator: AsyncStream<Bool>.Iterator

    init(_ stream: AsyncStream<Bool>) {
        iterator = stream.makeAsyncIterator()
    }

    /// Bounded, so a red test fails rather than hangs (`CLAUDE.md`, Testing).
    @MainActor
    func next() async -> Bool? {
        let box = Box()
        Task { @MainActor in
            box.value = await self.read()
            box.done = true
        }
        for _ in 0 ..< 2000 where !box.done {
            await Task.yield()
        }
        if !box.done {
            Issue.record("no value reached the stream")
        }
        return box.value
    }

    @MainActor
    private func read() async -> Bool? {
        await iterator.next(isolation: #isolation)
    }
}

@MainActor
private final class Box {
    var value: Bool?
    var done = false
}

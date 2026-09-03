import AppKit
import Foundation

/// **Spike instrumentation. Kept deliberately, for now.**
///
/// The first trial is recorded in `docs/protocol/findings.md` §16: no
/// throttling at all, windowless and inactive, for four minutes. Two follow-ups
/// named there need this file to still exist - the same run on battery, and the
/// same run on a build with no `MenuBarExtra` - so it stays until those are
/// answered rather than being deleted the moment one number looked good.
///
/// Session 1 listed one gating spike that was never run: whether App Nap
/// throttles a windowless `MenuBarExtra` agent holding a stream. It matters
/// because the Mac story is "your Mac stays synced while the app sits in the
/// menu bar", and a throttled agent turns that into "your Mac catches up when
/// you next look at it".
///
/// The probe records how long a one-second sleep actually takes, once a second,
/// to a CSV inside the container. Run it with `--probe=appnap`, optionally with
/// `--probe-activity` to hold a `beginActivity` assertion, and
/// `--probe-close-window` to drop to a windowless agent after ten seconds -
/// which is the condition being tested.
///
/// **What it measures, and what it does not.** This is `Task.sleep` cadence,
/// which is the same mechanism `FixtureDemoDriver` and any reconnect backoff
/// use. It is *not* URLSession stream delivery: a long poll is serviced by a
/// system daemon and may keep arriving while the app's own timers are stretched.
/// That second question needs live credentials and is recorded as still open.
@MainActor
public final class AppNapProbe {
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    public init() {}

    public func start(writingTo url: URL) {
        guard task == nil else { return }

        if CommandLine.arguments.contains("--probe-activity") {
            // The documented way to tell macOS this process is doing something
            // the user asked for. If it works, it is the mitigation.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "holding a chat session open"
            )
        }
        if CommandLine.arguments.contains("--probe-close-window") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                for window in NSApplication.shared.windows {
                    window.close()
                }
            }
        }

        try? "elapsedSeconds,gapMilliseconds,windows,active\n"
            .write(to: url, atomically: true, encoding: .utf8)

        task = Task { @MainActor in
            let start = Date()
            var previous = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Date()
                let line = String(
                    format: "%.1f,%.0f,%d,%@\n",
                    now.timeIntervalSince(start),
                    now.timeIntervalSince(previous) * 1000,
                    NSApplication.shared.windows.count { $0.isVisible },
                    NSApplication.shared.isActive ? "yes" : "no"
                )
                previous = now
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                    try? handle.close()
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

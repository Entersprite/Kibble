import Foundation
import GChatBridgeCore

/// `--probe=events`: every channel event type seen this run, and the shape of
/// its bodies, rewritten to one small file as each arrives
/// (`ChannelEventTally`). Diagnostic instrumentation for the in-a-meeting
/// spike; it never changes what the channel does.
extension LocalBridgeBackend {
    /// The file and what it has counted so far.
    struct EventTallyFile {
        let url: URL
        let startedAt: Date
        var tally = ChannelEventTally()
    }

    /// Starts tallying into `url`. `MacHost` hands over a plain `URL`, the
    /// same containment `tracingChannelTo` keeps: `PBLiteValue` and
    /// `ChannelEvent` are core types the app must not see.
    public func tallyEvents(to url: URL) {
        eventTally = EventTallyFile(url: url, startedAt: Date())
        writeTally()
    }

    func recordInTally(_ event: ChannelEvent) {
        guard eventTally != nil else { return }
        let now = Date()
        for body in event.bodies {
            eventTally?.tally.record(type: body.typeTag, body: body.value, at: now)
        }
        writeTally()
    }

    /// Rewritten whole, atomically, on every event: a run that is killed
    /// leaves the last complete tally, and events are few enough that the
    /// cost does not matter. A failed write is dropped, as the other trace
    /// sinks drop theirs - a diagnostic must not break the channel.
    private func writeTally() {
        guard let file = eventTally else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let text = file.tally.report(startedAt: file.startedAt, writtenAt: Date(), build: build)
        try? Data(text.utf8).write(to: file.url, options: .atomic)
    }
}

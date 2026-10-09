import ChatKit
import Foundation

// MARK: - The demo world's threads

extension Acme {
    /// A thread long enough to scroll its panel: Tom maps thirty trims, one
    /// reply each, and Alex checks every fifth. Generated, like `filler`,
    /// because the rows carry no narrative. Minutes are distinct and all
    /// before the world's newest message, so `startedAt` does not move.
    static let trimLines: [Line] = [
        Line(
            id: "msg:trim-root", conversation: catalog, thread: "topic:trim", sender: tom,
            text: "Trim mapping for the 2026 import, one reply per row as I go.",
            minute: -1380
        )
    ] + (1 ... 30).map { index in
        Line(
            id: "msg:trim-\(index)", conversation: catalog, thread: "topic:trim",
            sender: index.isMultiple(of: 5) ? alex : tom,
            text: index.isMultiple(of: 5)
                ? "Checked \(index - 4) to \(index) against the spec sheet."
                : "Trim \(index) of 30 mapped.",
            minute: -1380 + index,
            isReply: true
        )
    }

    /// What the server knows about the demo's threads beyond their messages
    /// (threads spec §1). Keyed by thread id, unique across this world, and
    /// never iterated, so its order cannot reach a frame.
    static let threadStates: [MessageThread.ID: FixtureThreadState] = [
        // Followed and read up to Priya's reply: three replies unread, one of
        // them mentioning Alex.
        MessageThread.ID("topic:variance"): FixtureThreadState(isFollowed: true, readPosition: at(34)),
        // Alex started this DM thread and replied last: followed and read.
        MessageThread.ID("topic:dm-dan"): FixtureThreadState(isFollowed: true, readPosition: at(-1385)),
        // Alex checked the last rows: followed and read.
        MessageThread.ID("topic:trim"): FixtureThreadState(isFollowed: true, readPosition: at(-1350))
    ]
}

// MARK: - A reply arrives

public extension FixtureScript {
    /// Replies landing in followed threads while you watch: a DM thread, then
    /// the long thread, each making its thread unread without making its
    /// conversation unread (threads spec §4.3). The tail of `acmeDemo`, so
    /// the Debug app plays it.
    static let acmeReplyArrives = FixtureScript(steps: [
        .delay(.seconds(4)),
        .incomingMessage(
            conversation: Acme.danDM,
            from: Acme.dan,
            text: "Incident doc is closed out, with the timeline.",
            thread: MessageThread.ID("topic:dm-dan")
        ),
        .delay(.seconds(6)),
        .incomingMessage(
            conversation: Acme.catalog,
            from: Acme.tom,
            text: "One more: trim 31 needed a manual mapping.",
            thread: MessageThread.ID("topic:trim")
        ),
        .delay(.seconds(8))
    ])
}

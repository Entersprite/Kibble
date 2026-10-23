import ChatKit
import Foundation

public extension FixtureWorld {
    /// What the app's demo shows: `acme` with its call records.
    static let acmeDemo = acme.withDemoCallHistory()

    /// The world with a few retained call records, for the app's demo of the
    /// Calls list and the transcript's call cards. Kept out of `acme` itself,
    /// whose message counts and order other suites read. Every record is
    /// older than its conversation's newest message, so no conversation's
    /// activity or preview moves. History only: nothing here makes a call
    /// look active.
    func withDemoCallHistory() -> FixtureWorld {
        var world = self
        world.messages = (messages + Acme.callRecords)
            .sorted { $0.createdAt < $1.createdAt }
        return world
    }
}

extension Acme {
    static let callRecords: [Message] = [
        record("msg:call-1", in: danDM, from: alex, status: .ended, minute: -1500),
        record("msg:call-2", in: priceEngine, from: priya, status: .ended, minute: 10),
        record("msg:call-3", in: mayaDM, from: maya, status: .missed, minute: 40),
        record("msg:call-4", in: launchTeam, from: alex, status: .started, minute: 50),
        record("msg:call-5", in: launchTeam, from: alex, status: .ended, minute: 53)
    ]

    /// Each record is its own topic, named after itself, as everywhere in
    /// this world.
    private static func record(
        _ id: String, in conversation: Conversation.ID, from sender: Member.ID,
        status: MessageCallStatus, minute: Int
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation,
            threadID: MessageThread.ID("topic:" + id.dropFirst("msg:".count)),
            sender: sender, text: "", createdAt: at(minute), callStatus: status
        )
    }
}

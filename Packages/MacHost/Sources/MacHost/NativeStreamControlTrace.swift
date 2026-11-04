import Foundation

/// Fixed transport phases and capped counts; never channel payloads or IDs.
struct NativeStreamControlTrace {
    enum Stage: String {
        case idle, openingChannel, waitingForReply, replyReceived
    }

    var stage: Stage = .idle
    var sent = false
    private(set) var received = 0
    private(set) var unmatched = 0
    private(set) var matched = 0

    mutating func receive(matched: Bool) {
        received = min(received + 1, 1_000_000)
        if matched {
            self.matched = min(self.matched + 1, 1_000_000)
            stage = .replyReceived
        } else {
            unmatched = min(unmatched + 1, 1_000_000)
        }
    }

    func line(channel: String) -> String {
        "Native stream control: stage=\(stage.rawValue); channel=\(channel); sent=\(sent); "
            + "received=\(received); unmatched=\(unmatched); matched=\(matched)"
    }
}

import ChatKit
import Foundation

/// The Convert to Space sheet's words for what a conversion does, from the
/// server's consequences. Only what it confirmed gets a line; what it
/// couldn't confirm is said once, plainly. Nothing is guessed.
enum ConversionText {
    /// The line for one confirmed consequence; nil for an unknown outcome,
    /// a topic Kibble can't name, or a combination with no wording.
    static func line(_ consequence: ConversionConsequence) -> String? {
        // By type alone: a token that arrived with extra fields is still the same token.
        switch (ConversionTopic(consequence.topic.type), ConversionOutcome(consequence.outcome.type)) {
        case (.sameConversation, .kept): "It stays the same conversation."
        case (.membership, .kept): "Everyone in it stays a member."
        case (.messages, .kept): "All messages are kept."
        case (.undo, .notReversible): "This can’t be undone."
        case (.history, .changed): "Conversation history settings will change."
        default: nil
        }
    }

    /// One sentence or two naming every topic whose outcome is unknown, in
    /// the order given; nil when there are none Kibble can name.
    static func unknownSummary(_ items: [ConversionConsequence]) -> String? {
        var seen = Set<String>()
        let topics = items
            .filter { $0.outcome.type == ConversionOutcome.unknown.type }
            .map(\.topic.type)
            .filter { seen.insert($0).inserted }
        let things = topics.compactMap { Self.subjects[$0] }
        let questions = topics.compactMap { Self.questions[$0] }
        var sentences: [String] = []
        if !things.isEmpty {
            sentences.append("Kibble can’t confirm what happens to \(list(things)).")
        }
        if !questions.isEmpty {
            let lead = sentences.isEmpty ? "Kibble can’t confirm" : "Kibble also can’t confirm"
            sentences.append("\(lead) \(list(questions)).")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// "what happens to …" for the topics that are things.
    private static let subjects: [String: String] = [
        ConversionTopic.membership.type: "members",
        ConversionTopic.messages.type: "messages",
        ConversionTopic.history.type: "conversation history settings",
        ConversionTopic.invitations.type: "invitations",
        ConversionTopic.integrations.type: "apps and webhooks",
        ConversionTopic.externalPeople.type: "external people"
    ]

    /// "whether …" for the topics that are yes-or-no.
    private static let questions: [String: String] = [
        ConversionTopic.sameConversation.type: "whether it stays the same conversation",
        ConversionTopic.undo.type: "whether this can be undone"
    ]

    /// "a", "a or b", "a, b, or c".
    private static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0, 1: parts.first ?? ""
        case 2: "\(parts[0]) or \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", or \(parts[parts.count - 1])"
        }
    }
}

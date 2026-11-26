/// The provider adapter has affirmative evidence that a message write never started.
/// Use an ordinary error when the provider might have received the submission.
public struct MessageNotSubmitted: Error, Sendable {
    public init() {}
}

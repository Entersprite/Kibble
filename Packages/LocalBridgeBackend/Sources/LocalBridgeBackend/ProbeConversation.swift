/// Which conversation `--probe=api` probes, from `--probe-conversation=`.
///
/// Owned by this package and parsed from a plain string, so `MacHost` hands
/// over the argument's text and names no core type.
public enum ProbeConversation: Sendable, Equatable {
    /// The conversation with the newest activity: the default.
    case mostRecent
    /// The newest direct message (`dm`), for a run staged in a DM on an
    /// account where a busy space would otherwise win (`findings.md` §52).
    case mostRecentDirectMessage
    /// An index in world order (`N`), which the report never names.
    case index(Int)

    /// `dm` in any case, a non-negative integer, or anything else as the
    /// default - an argument the probe cannot read must not stop the run.
    public init(argument: String) {
        if argument.lowercased() == "dm" {
            self = .mostRecentDirectMessage
        } else if let index = Int(argument), index >= 0 {
            self = .index(index)
        } else {
            self = .mostRecent
        }
    }
}

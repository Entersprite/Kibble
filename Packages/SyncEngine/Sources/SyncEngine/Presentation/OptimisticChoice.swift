import Foundation

/// A value the person just chose, shown before the service answers.
///
/// The choice is drawn at once and kept while its command is in flight. A
/// refused or uncertain command drops it, so the observed value shows again:
/// the only time anything springs back. An accepted one is kept until the
/// store catches up, so the old value never flashes between the answer and
/// its event, which can arrive in either order.
///
/// Pure, so the ordering rules are tests rather than timing.
struct OptimisticChoice<Value: Equatable> {
    private struct Pending {
        var value: Value
        var token: Int
        var accepted = false
    }

    private var pending: Pending?
    private var nextToken = 0
    private(set) var observed: Value

    init(observed: Value) {
        self.observed = observed
    }

    /// What to draw: the choice while one is pending, else what the store says.
    var shown: Value {
        pending?.value ?? observed
    }

    var isPending: Bool {
        pending != nil
    }

    /// Records a new choice and returns the token its answer must carry. A
    /// newer choice replaces an older one still in flight.
    mutating func choose(_ value: Value) -> Int {
        nextToken += 1
        pending = Pending(value: value, token: nextToken)
        return nextToken
    }

    /// The service answered the choice that `token` names. An answer for a
    /// choice that has since been replaced changes nothing.
    mutating func settle(_ token: Int, accepted: Bool) {
        guard let current = pending, current.token == token else { return }
        if accepted, current.value != observed {
            pending?.accepted = true
        } else {
            pending = nil
        }
    }

    /// A different subject, such as the local user becoming known: forget any
    /// choice and start from its stored value. Tokens keep counting, so a
    /// late answer cannot settle a later choice.
    mutating func rebase(observed value: Value) {
        pending = nil
        observed = value
    }

    /// The store delivered a value. Only a change counts: an unrelated write
    /// re-delivers the same value, and must not end an accepted choice before
    /// its own event has landed.
    mutating func observe(_ value: Value) {
        guard value != observed else { return }
        observed = value
        guard let current = pending else { return }
        if current.accepted || current.value == value {
            pending = nil
        }
    }
}

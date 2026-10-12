import os

/// What one `SBNmJb` page answered, in the unified log, the same reasoning as
/// `AvailabilityLog`: counts only, never an id or text, so a live run can be
/// read with `log show` instead of a search's own hits going anywhere this
/// agent (or anyone else) can read them back out of.
///
///     /usr/bin/log show --last 10m --predicate \
///         'subsystem == "com.entersprite.kibble" && category == "search"'
///
/// **Why a log line and not `.backendError`:** a dropped hit is a shape
/// `SearchHitMapping` does not yet recognise, not a failed request - the
/// search itself still answered and the person still sees their other
/// results. Raising a banner for it on every such search would teach people
/// to ignore search errors generally, so the count goes here instead, where
/// it stays visible to whoever is looking without interrupting anyone who is
/// not.
enum SearchLog {
    private static let log = Logger(subsystem: "com.entersprite.kibble", category: "search")

    static func page(hits: Int, dropped: Int, hasNext: Bool) {
        log.notice(
            """
            hits=\(hits, privacy: .public) dropped=\(dropped, privacy: .public) \
            next=\(hasNext, privacy: .public)
            """
        )
    }
}

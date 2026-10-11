import os

/// What one `SBNmJb` page answered, in the unified log, the same reasoning as
/// `AvailabilityLog`: counts only, never an id or text, so a live run can be
/// read with `log show` instead of a search's own hits going anywhere this
/// agent (or anyone else) can read them back out of.
///
///     /usr/bin/log show --last 10m --predicate \
///         'subsystem == "com.entersprite.kibble" && category == "search"'
///
/// **Why a log line and not `.backendError`:** a dropped hit (a shape
/// `SearchHitMapping` does not recognise) is not a failure a person should
/// see a banner about on every search - `CLAUDE.md`'s ruling for this task is
/// explicit that nothing emits for it.
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

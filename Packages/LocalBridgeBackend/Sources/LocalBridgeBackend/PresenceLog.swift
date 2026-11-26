import Foundation
import os

/// What each presence poll came to, in the unified log, so a live run - the
/// Mac waking with every dot gone - can be read with `log show` rather than
/// copied out of the sandbox, as `AvailabilityLog` does. Counts, booleans and
/// an error's domain and code only: no id, nobody's state.
///
///     /usr/bin/log show --last 10m --predicate \
///         'subsystem == "com.entersprite.kibble" && category == "presence"'
enum PresenceLog {
    private static let log = Logger(subsystem: "com.entersprite.kibble", category: "presence")

    static func answered(asked: Int, answered: Int) {
        log.notice("poll answered asked=\(asked, privacy: .public) answered=\(answered, privacy: .public)")
    }

    static func failed(asked: Int, error: any Error) {
        let error = error as NSError
        log.notice(
            """
            poll failed asked=\(asked, privacy: .public) \
            domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)
            """
        )
    }

    /// The loop started over at once: a channel came back after an outage.
    static func restarted() {
        log.notice("poll restarted: channel resumed")
    }
}

import Foundation

/// Decides what to call a user, given a local alias and a directory lookup.
///
/// Aliases exist because **Chat apps cannot be named from any API**: the Chat
/// API returns only `name` and `type` for a `User` under user authentication,
/// and the People API has no profile for an app because an app is not a Google
/// account. A locally-stored alias is therefore the only way to make bot-heavy
/// spaces readable.
///
/// The alias wins over the directory name too, so a person can be renamed to
/// whatever the user actually calls them.
public enum DisplayNameResolution {
    public static func name(
        forUser userName: String,
        aliases: [String: String],
        resolved: [String: String]
    ) -> String? {
        for candidate in [aliases[userName], resolved[userName]] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { continue }
            return trimmed
        }
        return nil
    }
}

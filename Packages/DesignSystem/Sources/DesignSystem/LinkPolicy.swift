import Foundation
import SwiftUI

/// The one rule for what a click may open (links spec §7.1): web pages and
/// mail, nothing else. A message is someone else's text, and a `file:`,
/// `javascript:` or app-scheme link in it must not run anything here.
public enum LinkPolicy {
    static let schemes: Set = ["http", "https", "mailto"]

    public static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }

    /// Installed over the transcript, so every SwiftUI link and every
    /// `openURL` call under it passes the same rule.
    @MainActor public static let openURLAction = OpenURLAction { url in
        canOpen(url) ? .systemAction : .discarded
    }
}

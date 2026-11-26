import Foundation
import SwiftUI

/// The one rule for what a click may open (links spec §7.1): web pages and
/// mail, nothing else. A message is someone else's text, and a `file:`,
/// `javascript:` or app-scheme link in it must not run anything here.
public enum LinkPolicy {
    static let schemes: Set = ["http", "https", "mailto"]

    public static func canOpen(_ url: URL, blocking hosts: Set<String> = []) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme) && !hosts.contains(url.host()?.lowercased() ?? "")
    }

    /// Installed over the transcript, so every SwiftUI link and every
    /// `openURL` call under it passes the same rule.
    @MainActor public static let openURLAction = OpenURLAction { url in
        canOpen(url) ? .systemAction : .discarded
    }

    @MainActor public static func openURLAction(blocking hosts: Set<String>) -> OpenURLAction {
        OpenURLAction { url in canOpen(url, blocking: hosts) ? .systemAction : .discarded }
    }

    @MainActor static func openURLAction(
        blocking hosts: Set<String>, meetingHosts: Set<String>, join: ((URL) -> Void)?
    ) -> OpenURLAction {
        OpenURLAction { url in
            guard canOpen(url, blocking: hosts) else { return .discarded }
            if let join, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
               meetingHosts.contains(url.host()?.lowercased() ?? ""), url.absoluteString.utf8.count <= 2048 {
                join(url)
                return .handled
            }
            return .systemAction
        }
    }

    static func isMeetingLink(_ url: URL, hosts: Set<String>) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.fragment == nil
            && hosts.contains(url.host()?.lowercased() ?? "") && url.path != "/" && !url.path.isEmpty
            && url.absoluteString.utf8.count <= 2048
    }
}

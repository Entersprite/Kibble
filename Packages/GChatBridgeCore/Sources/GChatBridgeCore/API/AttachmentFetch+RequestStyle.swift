import Foundation

public extension AttachmentFetch {
    /// How each hop is asked. The app's style is the default; the others
    /// exist so the download probe can tell which difference from a browser
    /// `chat.usercontent.google.com` refuses (`findings.md` §52.4). Chat on
    /// the web downloads a file by navigating a new tab to it.
    struct RequestStyle: Sendable, Hashable {
        /// A browser navigation's `Sec-Fetch-*`, `Upgrade-Insecure-Requests`
        /// and `Accept`, with `Sec-Fetch-Site` computed over the chain the
        /// way a browser computes it for a redirect.
        public var navigation: Bool
        /// `Referer: https://<chat host>/` - the origin only, which is what a
        /// browser's default referrer policy sends off-origin - to Google
        /// hosts only.
        public var referer: Bool
        /// Whether `get_attachment_url` is sent `content_type`. purple sends
        /// it; mautrix leaves it out for `DOWNLOAD_URL` (§52.1).
        public var sendsContentType: Bool
        /// Cookie names sent to the chat host and withheld from every other
        /// host. The jar keeps no domains, so without this a sibling such as
        /// `chat.usercontent.google.com` is sent `COMPASS` and `OSID`, which
        /// a browser keeps for `chat.google.com` alone (`findings.md` §52.8).
        public var chatHostOnly: Set<String>

        public init(
            navigation: Bool = false,
            referer: Bool = false,
            sendsContentType: Bool = true,
            chatHostOnly: Set<String> = []
        ) {
            self.navigation = navigation
            self.referer = referer
            self.sendsContentType = sendsContentType
            self.chatHostOnly = chatHostOnly
        }

        public static let app = RequestStyle()
    }
}

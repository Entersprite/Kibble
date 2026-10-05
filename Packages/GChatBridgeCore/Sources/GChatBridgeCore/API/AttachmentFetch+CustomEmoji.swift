import Foundation

/// A workspace custom emoji's picture, the way Chat on the web loads one
/// (`findings.md` §54.4): `get_custom_emoji_image` with the emoji's
/// `read_token`, one 302 to `lh3.googleusercontent.com`, and the image from
/// there. Walked by `fetch(url:)`, so credentials go by host as for every
/// attachment: the session to the chat host, nothing to `googleusercontent`.
///
/// `[Verify]`: which cookies either host needs (the capture was exported
/// without cookies), whether a `read_token` expires, and that this client's
/// fetch succeeds at all - no run of it has happened yet.
public extension AttachmentFetch {
    func customEmojiImage(readToken: String) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        try await fetch(url: customEmojiImageURL(readToken: readToken))
    }

    /// Under the account segment: Chat on the web's request without it was
    /// answered with a redirect to this form.
    internal func customEmojiImageURL(readToken: String) -> URL {
        let base = endpoints.base
            .appendingPathComponent("api")
            .appendingPathComponent("get_custom_emoji_image")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([("custom_emoji_read_token", readToken)])
        return components.url!
    }
}

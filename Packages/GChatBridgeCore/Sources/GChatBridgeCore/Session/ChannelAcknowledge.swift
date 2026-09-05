import Foundation

/// The driver's half of the `.acknowledge` effect.
///
/// Split out of `ChannelSession.swift` rather than added to it because that
/// file was already at 395 lines against swiftlint's 400-line `file_length`
/// ceiling (checked under `--strict`) - the same trade `NetworkWait.swift`
/// already makes, and for the same reason: every input this needs is passed
/// in explicitly rather than read from `ChannelSession`'s own stored
/// properties, so it needs no access to anything `private` there.
extension ChannelSession {
    /// Sends the acknowledge request and waits only for its headers.
    ///
    /// **This is what makes the ack genuinely fire-and-forget, not merely
    /// commented as one.** Before this fix, `ChannelSession.handle(_:)`'s
    /// `.acknowledge` arm read `send(requests.acknowledge(...)) {}` -
    /// `send(_:)` awaits the transport's *whole* response body - and
    /// `--probe=channeltrace` against a live account measured the server
    /// holding that body open for **~64 seconds**. Because `openStream(_:)`
    /// calls `acknowledgeIfPending()` before its own body-read loop, every one
    /// of those 64 seconds passed with no long poll being read at all, even
    /// though its bytes were already sitting in the transport's buffered
    /// stream: the trace showed the handshake's own body arriving and ending
    /// within half a second of being opened, then a 64.489-second gap before
    /// the next `open` - the reopen `.bodyEnded` should have queued
    /// immediately, stalled the whole time behind this call.
    ///
    /// `transport.fireAndForget(_:)` returns as soon as this response's
    /// *headers* arrive and never reads its body at all - see that method's
    /// own doc comment on `HTTPTransport`. This mirrors the reference
    /// exactly: `fetch_raw` returns a `ClientResponse` at headers and never
    /// reads this response's body either (`channel.py:440-442`,
    /// `http_utils.py:175-205`) - nobody, including the reference's own
    /// author, knows what this request is *for* beyond "it does seem to be
    /// required".
    ///
    /// - Parameters:
    ///   - request: Already authorised - the caller attaches the current
    ///     cookie jar before this runs, the same as every other request.
    ///   - transport: Passed explicitly rather than read from `self.transport`,
    ///     which is what lets this live outside `ChannelSession.swift`.
    ///   - onHeaders: What the caller does with the response's headers -
    ///     `ChannelSession.absorb(_:)` in production, so a rotated cookie on
    ///     even this response is not silently dropped.
    ///   - onFailure: What the caller does when the request fails outright -
    ///     `ChannelSession.apply(.failed(_:))` in production. A failure here
    ///     still reports and reconnects like any other transport failure;
    ///     what changed is only that success no longer waits on the body.
    static func acknowledge(
        _ request: HTTPRequest,
        via transport: any HTTPTransport,
        onHeaders: @Sendable (HTTPHeaders) async -> Void,
        onFailure: @Sendable (ChannelFailure) async -> Void
    ) async {
        do {
            let headers = try await transport.fireAndForget(request)
            await onHeaders(headers)
        } catch let classified as ClassifiedTransportFailure {
            await onFailure(.transport(classified.reason))
        } catch {
            await onFailure(.transport(nil))
        }
    }
}

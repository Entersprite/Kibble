import Foundation

/// Header-only POST control requests for ping and group subscription.
/// The handshake's X-HTTP-Initial-Response already establishes the receive
/// stream; a second RID=rpc GET would compete for that same session.
extension ChannelSession {
    /// Controls wait for headers only, so a held POST response body cannot
    /// prevent the account from consuming incoming events.
    static func sendControl(
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

    /// Authorises and sends the initial ping if the caller managed to build
    /// one - or does nothing at all otherwise.
    ///
    /// `request` arrives already-optional and **not yet authorised** - the
    /// caller (`ChannelSession.handle(_:)`'s `.sendInitialPing` arm) passes
    /// `requests.ping(...)`'s result straight through, unguarded, which is
    /// what keeps that arm - already carrying the counter bookkeeping - a
    /// single straight-line statement under swiftlint's
    /// `cyclomatic_complexity` ceiling; the nil check and the
    /// `credentials.authorisingChannel(_:)` call both live here instead, and taking
    /// `credentials` itself rather than an already-authorised request is what
    /// keeps this function at exactly five parameters, swiftlint's
    /// `function_parameter_count` ceiling. `nil` means
    /// `ChannelRequests.ping(...)` could not encode the event - see that
    /// method's own doc comment for why that should not happen, and why this
    /// is a silent no-op rather than a reported failure regardless: the ping
    /// is an accelerant for delivery, not the mechanism, and a channel that
    /// cannot build one diagnostic form continues exactly as if it had been
    /// dropped on the wire.
    static func sendInitialPingIfPossible(
        _ request: HTTPRequest?,
        credentials: SessionCredentials,
        via transport: any HTTPTransport,
        onHeaders: @Sendable (HTTPHeaders) async -> Void,
        onFailure: @Sendable (ChannelFailure) async -> Void
    ) async {
        guard let request else {
            return
        }
        await sendControl(
            credentials.authorisingChannel(request), via: transport, onHeaders: onHeaders,
            onFailure: onFailure
        )
    }

    /// `onHeaders` for `sendInitialPingIfPossible`: absorbs from the ping's
    /// own URL, from `request.url` before `authorising` attaches cookies to
    /// it - and does nothing when `pingURL` is `nil`, which is the same
    /// silent no-op `sendInitialPingIfPossible` itself falls back to when no
    /// ping could be built.
    static func onPingHeaders(
        pingURL: URL?,
        credentials: SessionCredentials
    ) -> @Sendable (HTTPHeaders) async -> Void {
        { headers in
            guard let pingURL else { return }
            await credentials.absorb(headers, from: pingURL)
        }
    }
}

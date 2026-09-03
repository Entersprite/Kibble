import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The channel's cookie rotation, reaching the credential store.
///
/// Split out of `LiveChannelTests` rather than added to it because that file
/// hit swiftlint's 400-line ceiling once task 3 of the reconnect taxonomy's
/// fixes were added - the same trade that file's own doc comment already
/// makes for its private helpers: `cookies` and `shell()` below are copies of
/// its namesakes, and a few lines of duplicated scaffolding is cheaper than
/// routing a single test through a shared type nobody else reads.
struct LiveChannelRotationTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func shell() -> Result<HTTPResponse, any Error> {
        ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi"))
    }

    /// The whole reason `ChannelSession` takes an `onRotation`: a session that
    /// rotates mid-stream has to be written back, or the next launch replays a
    /// credential that went stale on the first poll.
    ///
    /// Was two non-shell responses (register, ack). Since task 3 of the
    /// reconnect taxonomy that undercount became a hang rather than a
    /// tolerated race: `connect()` also races `resolveAndEmitSelf()` for this
    /// same queue, so with only two responses for three concurrent callers
    /// (register, ack, `resolveAndEmitSelf()`), whichever one lost used to
    /// produce a `.transport` failure that the old four-attempt bound simply
    /// absorbed and stopped on. That bound is gone, so the same lost race now
    /// retries forever - at register/ack, never reaching the terminal stream
    /// scripted below for the reopen. Two extra responses remove the race
    /// entirely, generously, the same way `LiveChannelTests`'s own tests that
    /// race `resolveAndEmitSelf()` already do.
    @Test func aCookieRotatedOnTheChannelIsHandedToTheCredentialStore() async throws {
        let transport = ScriptedTransport(
            [
                shell(),
                .success(HTTPResponse(
                    status: 200,
                    headers: HTTPHeaders([("Set-Cookie", "COMPASS=grown; Path=/")]),
                    body: Data()
                )),
                ScriptedTransport.ok(""),
                ScriptedTransport.ok(""),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                ),
                // Since task 3 of the reconnect taxonomy a transport failure
                // never gives up on its own, so without this the channel
                // would reopen forever once the stream above ends cleanly
                // (there is nothing further scripted for it), and
                // `waitForChannel()` below would hang. A deliberate terminal
                // status ends it after the rotation this test is about has
                // already been absorbed.
                ScriptedTransport.Script(status: 403, chunks: [])
            ]
        )
        let rotations = Rotations()
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            // Same reason as the `waitForChannel()` tests in `LiveChannelTests`:
            // this one waits for the channel to finish.
            retry: .immediate,
            onRotation: { await rotations.record($0) }
        )
        try await backend.connect()
        // Let the channel run to its end so the register response is absorbed.
        await backend.waitForChannel()
        #expect(await rotations.count >= 1)
    }
}

private actor Rotations {
    private(set) var count = 0

    func record(_: SessionCookies) {
        count += 1
    }
}

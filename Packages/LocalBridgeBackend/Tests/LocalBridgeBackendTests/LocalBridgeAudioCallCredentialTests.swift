import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
extension LocalBridgeAudioCallServiceTests {
    @Test func chatAndCallsUseOneLiveJarAcrossRotationsAndCallShutdown() async throws {
        var responses = nativeResponses(outgoing: true)
        var shell = try responses[0].get()
        shell.headers = HTTPHeaders([("Set-Cookie", "NID=call-rotation; Domain=.google.com; Path=/")])
        responses[0] = .success(shell)
        let setup = try await setup(responses)
        let capture = try #require(try await setup.store.snapshot())
        let original = capture.session
        let backend = LocalBridgeBackend(
            cookies: original.credential, transport: setup.transport, retry: .immediate,
            onRotation: { rotated in
                try? await setup.store.replaceCredential(with: rotated, belongingTo: capture)
            }
        )
        let summary = try #require(try await setup.store.summary(at: Date()))
        let service = await backend.makeAudioCallService(
            store: setup.store, expectedSession: summary, mediaFactory: { setup.media.make() }
        )
        try await service.startListening()
        try await backend.credentials.absorb(
            HTTPHeaders([("Set-Cookie", "SAPISID=chat-rotation; Domain=.google.com; Path=/")]),
            from: #require(URL(string: "https://chat.google.com/"))
        )
        let person = try #require(service.people.values.first)
        let id = UUID()
        try await service.startOutgoing(to: LocalBridgeAudioCallService.recipient(person), callID: id)
        let request = try #require(await setup.base.sent.first { $0.url.path == "/call" })
        #expect(request.headers["Cookie"]?.contains("SAPISID=chat-rotation") == true)
        #expect(request.headers["Cookie"]?.contains("cookie-sentinel") == false)
        let credentials = try #require(await backend.credentials.snapshot)
        let chatCookies = try credentials.header(for: #require(URL(string: "https://chat.google.com/")))
        #expect(chatCookies?.contains("NID=call-rotation") == true)
        #expect(try await setup.store.currentSession()?.credential == credentials)
        await service.stop()
        #expect(await backend.credentials.snapshot == credentials)
    }

    @Test func oldBackendRotationCannotOverwriteFreshLoginOrRestoreOldMeetCookies() async throws {
        let setup = try await setup()
        let capture = try #require(try await setup.store.snapshot())
        let original = capture.session
        let oldBackend = try #require(try await LocalBridgeBackend.using(
            setup.store, transport: setup.transport, retry: .immediate, reachability: nil
        ))
        try await setup.store.invalidate()
        let replacement = try StoredSession(
            credential: #require(SessionCookies(cookies: [
                .init(name: "SAPISID", value: "fresh-login", domain: ".google.com", path: "/")
            ])),
            capturedAt: original.capturedAt.addingTimeInterval(1), expiresAt: nil
        )
        try await setup.store.store(replacement)
        try await oldBackend.credentials.absorb(
            HTTPHeaders([("Set-Cookie", "SAPISID=stale-rotation; Domain=.google.com; Path=/")]),
            from: #require(URL(string: "https://chat.google.com/"))
        )
        #expect(try await setup.store.currentSession() == replacement)
    }

    @Test func freshChatLoginDropsPriorMeetCookiesAndShowsCallSignInFailureBeforeAudio() async throws {
        let redirect = HTTPResponse(
            status: 302,
            headers: HTTPHeaders([(
                "Location",
                "https://accounts.google.com/signin?opaque=private-sentinel"
            )]),
            body: Data()
        )
        let setup = try await setup([.success(redirect)])
        let capture = freshChatCapture()
        #expect(try await capture.save(to: setup.store))
        let fresh = try #require(try await setup.store.currentSession())
        #expect(!fresh.credential.cookies.contains { $0.name == "MOSID" })
        let summary = try #require(try await setup.store.summary(at: Date()))
        let backend = LocalBridgeBackend(
            cookies: fresh.credential,
            transport: setup.transport,
            retry: .immediate
        )
        let service = await backend.makeAudioCallService(
            store: setup.store, expectedSession: summary, mediaFactory: { setup.media.make() }
        )
        try await service.startListening()
        let person = try #require(service.people.values.first)
        await #expect(throws: ChatError.self) {
            try await service.startOutgoing(to: LocalBridgeAudioCallService.recipient(person), callID: UUID())
        }
        #expect(service.snapshot?.failureMessage
            == "Call sign-in is required. The calling service redirected to sign-in.")
        #expect(setup.media.engines.isEmpty)
        #expect(await !(service.report).contains("private-sentinel"))
        await service.stop()
    }

    @Test func stoppingCallListenerDoesNotCancelConcurrentChatRequestOnSharedTransport() async throws {
        let response = HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data("chat-response".utf8))
        let setup = try await setup([.success(response)], hold: "list_topics")
        let stored = try #require(try await setup.store.currentSession())
        let summary = try #require(try await setup.store.summary(at: Date()))
        let backend = LocalBridgeBackend(
            cookies: stored.credential,
            transport: setup.transport,
            retry: .immediate
        )
        let service = await backend.makeAudioCallService(
            store: setup.store, expectedSession: summary, mediaFactory: { setup.media.make() }
        )
        try await service.startListening()
        let chat = Task {
            let response = try await setup.transport.send(HTTPRequest(
                url: URL(string: "https://chat.google.com/api/list_topics")!
            ))
            try Task.checkCancellation()
            return response
        }
        try await waitForHold(setup)
        await service.stop()
        await setup.transport.release()
        #expect(try await chat.value.status == 200)
        #expect(try await chat.value.body == Data("chat-response".utf8))
        #expect(setup.media.engines.isEmpty)
    }

    private func freshChatCapture() -> CookieCapture {
        CookieCapture(
            cookies: [
                .init(
                    name: "SAPISID",
                    value: "new-chat-cookie",
                    domain: ".google.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: true,
                    expiresAt: nil
                ),
                .init(
                    name: "MOSID",
                    value: "old-meet-cookie",
                    domain: "meet.google.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: true,
                    expiresAt: nil
                )
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
            pageURL: "https://chat.google.com/", pageTitle: "Google Chat"
        )
    }
}

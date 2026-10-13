import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetRepeatCallTests {
    @Test func freshSecondSessionAcceptsURLSafeServerFragmentAfterFirstDeviceLeaves() async throws {
        let fragment = String(repeating: "U", count: 26) + "-_"
        let replies = NativeMeetFixture.responses() + NativeMeetFixture.responses(ufrag: fragment)
        let transport = ScriptedTransport(replies)
        let firstMedia = NativeFakeMedia()
        let first = try await NativeMeetFixture.session(transport, media: firstMedia)
        try await first.connect()
        await first.close()
        let secondMedia = NativeFakeMedia()
        let second = try await NativeMeetFixture.session(transport, media: secondMedia)
        try await second.connect()
        #expect(secondMedia.calls == ["offer", "answer", "connected"])
        #expect(secondMedia.answer?.contains("a=ice-ufrag:" + fragment + "\r\n") == true)
        let sent = await transport.sent
        #expect(sent.filter { $0.url.path.hasSuffix("ResolveForHangoutsChat") }.count == 2)
        #expect(sent.filter { $0.url.path.hasSuffix("CreateMediaSession") }.count == 2)
        #expect(sent.filter { $0.url.path.hasSuffix("CreateMeetingDevice") }.count == 2)
        #expect(!sent.contains { $0.url.path.hasSuffix("CreateMeetingInvite") })
        await second.close()
        #expect(secondMedia.calls.last == "close")
        #expect(await transport.sent.count == 10)
        let report = await second.takeReport().joined(separator: "\n")
        #expect(report.contains("JOINED accepted"))
        #expect(report.contains("device leave settled"))
        #expect(!report.contains(fragment))
    }
}

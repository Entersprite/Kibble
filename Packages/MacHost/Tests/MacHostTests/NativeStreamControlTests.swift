import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

@MainActor
struct NativeStreamControlTests {
    @Test func unrelatedFramesCannotDisplaceTheExpectedReply() async throws {
        let media = NativeCallMedia(presentation: true)
        let (peer, _) = try media.preparePeer(serverControlChannel: nil)
        defer { media.close() }
        let channel = try #require(peer.dataChannel(
            forLabel: "dcrpc", configuration: LKRTCDataChannelConfiguration()
        ))
        media.streamChannel = channel
        media.isExchangingStream = true
        let expected = Data([255])
        media.streamReplyMatches = { $0 == expected }
        for value in 1 ... 32 {
            media.dataChannel(channel, didReceiveMessageWith: LKRTCDataBuffer(
                data: Data([UInt8(value)]), isBinary: true
            ))
        }
        media.dataChannel(channel, didReceiveMessageWith: LKRTCDataBuffer(data: expected, isBinary: true))
        for value in 1 ... 32 {
            media.dataChannel(channel, didReceiveMessageWith: LKRTCDataBuffer(
                data: Data([UInt8(value)]), isBinary: true
            ))
        }
        media.dataChannel(channel, didReceiveMessageWith: LKRTCDataBuffer(data: expected, isBinary: true))
        for _ in 0 ..< 1000 where media.streamTrace.received < 66 {
            await Task.yield()
        }
        #expect(media.streamReplies == [expected])
        #expect(media.streamTrace.received == 66)
        #expect(media.streamTrace.unmatched == 64)
        #expect(media.streamTrace.matched == 2)
        #expect(media.streamControlDiagnosticReport().contains { $0.contains("stage=replyReceived") })
        media.close()
        media.dataChannel(channel, didReceiveMessageWith: LKRTCDataBuffer(data: expected, isBinary: true))
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(media.streamReplies.isEmpty && media.streamReplyMatches == nil)
        #expect(media.streamTrace.received == 0)
    }
}

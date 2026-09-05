import Foundation
import GChatBridgeCore
import Testing
@testable import URLSessionTransport

/// `ChannelTraceFileSink` itself is a thin, deliberately untested
/// file-writing boundary - the same shape this repo already accepts for
/// `SecItem` and `WKWebView` (see its own doc comment). `formattedFields(_:)`
/// is the one piece of genuinely pure logic it added for the `/api/` trace,
/// so it alone gets a direct test with synthetic input - no file, no socket.
@Suite("Channel trace file sink - pure formatting")
struct ChannelTraceFileSinkTests {
    @Test("field number, wire type and byte count are joined with \":\", fields with \"|\"")
    func fieldsAreCompactlyJoined() {
        let shape = ProtoShape(
            fields: [
                ProtoField(number: 1, wireType: 0, byteCount: 1),
                ProtoField(number: 4, wireType: 2, byteCount: 37)
            ],
            truncated: false
        )
        #expect(ChannelTraceFileSink.formattedFields(shape) == "1:0:1|4:2:37")
    }

    @Test("no fields formats as an empty string, not a stray separator")
    func noFieldsFormatsEmpty() {
        #expect(ChannelTraceFileSink.formattedFields(ProtoShape(fields: [], truncated: false)) == "")
    }
}

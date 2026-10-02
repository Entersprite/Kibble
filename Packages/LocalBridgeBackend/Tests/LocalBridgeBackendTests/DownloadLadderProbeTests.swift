import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The download probe's header ladder (`findings.md` §52.4), and the content
/// type key every attachment section prints.
struct DownloadLadderProbeTests {
    /// Each rung adds one difference from the app's request, so the first
    /// rung that succeeds names the difference that matters.
    @Test func theRungsAddOneDifferenceEach() {
        #expect(APIProbeReport.downloadLadder.map(\.style) == [
            AttachmentFetch.RequestStyle(navigation: true),
            AttachmentFetch.RequestStyle(navigation: true, referer: true),
            AttachmentFetch.RequestStyle(navigation: true, referer: true, sendsContentType: false),
            AttachmentFetch.RequestStyle(sendsContentType: false)
        ])
        #expect(Set(APIProbeReport.downloadLadder.map(\.label)).count == 4)
    }

    /// §52.3 printed `application/json; charset=utf-8` as "unusual": a
    /// charset parameter is part of an ordinary type.
    @Test(arguments: ["application/json; charset=utf-8", "text/html;charset=UTF-8"])
    func aCharsetIsOrdinary(_ type: String) {
        #expect(APIProbeReport.contentTypeKey(type) == type)
    }

    /// Anything else after the type could carry anything, so it is still
    /// only a length.
    @Test(arguments: [
        "application/json; name=secretvalue",
        "application/json; charset=utf-8; x=y",
        "not a type"
    ])
    func anythingElseIsALength(_ type: String) {
        #expect(APIProbeReport.contentTypeKey(type) == "(unusual, \(type.count) chars)")
    }
}

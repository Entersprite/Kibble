import Foundation
import GChatBridgeCore
import Testing
@testable import URLSessionTransport

/// Header values go out as their UTF-8 bytes. `URLRequest` writes a value as
/// Latin-1 and cuts it at the first character Latin-1 cannot hold (measured
/// against a local listener, session 50), so a value outside ASCII is handed
/// over one character per byte.
@Suite("URLSession transport - header encoding")
struct URLSessionTransportHeaderEncodingTests {
    @Test("an ASCII value is unchanged")
    func asciiIsUnchanged() {
        #expect(URLSessionTransport.wireValue("SID=abc; COMPASS=x") == "SID=abc; COMPASS=x")
    }

    @Test("a value outside ASCII becomes one character per UTF-8 byte, none lost")
    func utf8BytesSurvive() {
        let name = "\u{D3}rarend2 caf\u{E9} 9.41\u{202F}PM.pdf"
        let wire = URLSessionTransport.wireValue(name)
        #expect(wire.unicodeScalars.map(\.value) == name.utf8.map { UInt32($0) })
        #expect(wire.unicodeScalars.allSatisfy { $0.value <= 0xFF })
    }

    @Test("the request the loading system is given carries the bytes")
    func requestCarriesTheBytes() throws {
        let request = try HTTPRequest(
            url: #require(URL(string: "https://chat.google.com/uploads")),
            headers: HTTPHeaders([("x-goog-upload-file-name", "caf\u{E9}.png")])
        )
        let built = URLSessionTransport.urlRequest(from: request)
        let value = try #require(built.value(forHTTPHeaderField: "x-goog-upload-file-name"))
        #expect(value.unicodeScalars.map(\.value) == [0x63, 0x61, 0x66, 0xC3, 0xA9, 0x2E, 0x70, 0x6E, 0x67])
    }
}

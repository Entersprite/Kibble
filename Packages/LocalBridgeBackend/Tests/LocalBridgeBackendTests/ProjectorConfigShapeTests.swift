import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The viewer config's shape, masked by parsing (`CLAUDE.md`): the whole body
/// is decoded, every string leaf becomes its length, and a URL becomes its host
/// and the names of its query parameters. The sentinels are lowercase plain
/// words, inside the exceptions the masker makes for hosts and names.
struct ProjectorConfigShapeTests {
    private static func shape(_ json: String) -> String {
        ProjectorConfigShape.render(Data(json.utf8))
    }

    @Test("a URL leaf is its host, a plain first path segment, and its parameter names")
    func urlLeaf() {
        let rendered = Self
            .shape(#"["https://chat.usercontent.google.com/download?url_type=secretvalue&auth=tokenword"]"#)
        #expect(rendered == "[url(chat.usercontent.google.com /download ?url_type,auth)]")
    }

    @Test("a path segment that is not a plain word is reduced")
    func pathWithAnIdentifier() {
        let rendered = Self.shape(#"["https://lh3.googleusercontent.com/fife/abc123secretid=w100"]"#)
        #expect(rendered == "[url(lh3.googleusercontent.com /fife/… ?-)]")
        #expect(!rendered.contains("abc123"))
    }

    @Test("a host that is not a plain Google host is its last two labels")
    func foreignHost() {
        #expect(Self
            .shape(#"["https://doc-0s-secretname.example.org/x"]"#) == "[url(example.org (+1 label) /x ?-)]")
    }

    @Test("plain strings, numbers, booleans and null")
    func scalars() {
        #expect(Self.shape(#"["secretword", 7, 123456, true, null]"#) == "[s10,7,n6,true,null]")
    }

    @Test("an object keeps identifier keys and masks any other key")
    func objectKeys() {
        #expect(Self.shape(#"{"downloadUrl": "secretword", "secret key with spaces": 1}"#)
            == "{downloadUrl:s10,k22:1}")
    }

    @Test("the XSSI prefix is stripped before parsing")
    func xssiPrefix() {
        #expect(Self.shape(")]}'\n[1]") == "[1]")
    }

    @Test("long arrays and deep nesting are cut, saying so")
    func limits() {
        let long = "[" + Array(repeating: "1", count: 30).joined(separator: ",") + "]"
        #expect(Self.shape(long).hasSuffix(",…+10]"))
        let deep = String(repeating: "[", count: 12) + String(repeating: "]", count: 12)
        #expect(Self.shape(deep).contains("…"))
    }

    @Test("a body that is not JSON is reported by size, never printed")
    func notJSON() {
        #expect(ProjectorConfigShape.render(Data("secretword not json".utf8)) == "not JSON (19 bytes)")
    }

    /// Nothing from inside a value reaches the line, whatever its case.
    @Test("no sentinel survives")
    func noSentinel() {
        let rendered = Self.shape(#"""
        {"a": ["https://chat.usercontent.google.com/download/secretpath?k=secretvalue", "secretword",
               {"nested": "secretnested"}], "b": "SECRETUPPER"}
        """#)
        for sentinel in ["secretpath", "secretvalue", "secretword", "secretnested", "SECRETUPPER"] {
            #expect(!rendered.contains(sentinel), "\(sentinel)")
        }
    }

    @Test("the probe section prints the chain, the type, the size and the shape")
    func sectionLines() {
        let fetched = FetchedAttachment(
            body: Data((")]}'\n" + #"["https://chat.usercontent.google.com/download?auth=secretvalue"]"#)
                .utf8),
            contentType: "application/json",
            hops: [AttachmentHop(host: "chat.google.com", status: 200, carriedCredentials: true)]
        )
        let lines = APIProbeReport.projectorConfigLines(label: "/u/0", outcome: .success(fetched))
        #expect(lines == [
            "  /u/0: chat.google.com 200 (credentials)",
            "    content type application/json, \(fetched.body.count) bytes",
            "    shape: [url(chat.usercontent.google.com /download ?auth)]"
        ])
    }
}

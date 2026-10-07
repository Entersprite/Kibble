import Foundation
import Testing
@testable import DesignSystem

struct LinkPolicyTests {
    @Test(arguments: [
        "https://acme.example", "http://acme.example", "mailto:ops@acme.example", "HTTPS://ACME.EXAMPLE"
    ])
    func webAndMailOpen(_ raw: String) throws {
        #expect(try LinkPolicy.canOpen(#require(URL(string: raw))))
    }

    /// Review Focus 3.
    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/hosts", "slack://open", "ftp://acme.example", "data:text/html,x"
    ])
    func nothingElseOpens(_ raw: String) throws {
        #expect(try !LinkPolicy.canOpen(#require(URL(string: raw))))
    }
}

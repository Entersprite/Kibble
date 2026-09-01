import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

public extension LocalBridgeBackend {
    /// Builds a bridge from a captured `Cookie` header.
    ///
    /// Exists so a host does not have to import `GChatBridgeCore` to construct
    /// one. That is not tidiness: the app importing the core would put the
    /// generated protobuf's type names - `Message`, `Member`, `Group` - into
    /// the same scope as the domain's, and every app file would need
    /// qualifying. Worse, it would quietly break the containment that lets a
    /// future iOS binary carry no reverse-engineered code, which `test.sh` now
    /// enforces.
    ///
    /// Returns `nil` when the header contains nothing usable, which is a
    /// different thing from a header that authenticates and is rejected.
    static func capturing(header: String) -> LocalBridgeBackend? {
        guard let cookies = SessionCookies(header: header) else { return nil }
        return LocalBridgeBackend(cookies: cookies, transport: URLSessionTransport())
    }
}

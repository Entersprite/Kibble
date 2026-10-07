import ChatKit
import Foundation
import GChatBridgeCore

/// A link preview's or app card's picture - `remoteImage(_:)` (links spec
/// §4.4) - through `RemoteImageFetch`, which holds no credentials and so can
/// send none, even to `chat.google.com`. Needs no session, because it uses
/// none. The error names the failure, never the URL.
///
/// Whether Google's `image_url`s are on its own proxy or on the linked site is
/// `[Verify]` (`findings.md` §60); the owner chose to load them either way,
/// as Chat on the web does.
public extension LocalBridgeBackend {
    func remoteImage(_ url: URL) async throws -> Data {
        do {
            return try await RemoteImageFetch(transport: transport).image(at: url)
        } catch {
            throw ChatError.unknown("a remote image could not be loaded (\(error))")
        }
    }
}

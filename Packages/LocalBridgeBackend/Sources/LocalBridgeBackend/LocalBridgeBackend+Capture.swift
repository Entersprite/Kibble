import GChatBridgeCore

public extension LocalBridgeBackend {
    /// The User-Agent a capture window must present.
    ///
    /// Forwarded from the core so the login web view and the transport cannot
    /// disagree. Chat gates on this: without an accepted string it
    /// authenticates the session and then serves its unsupported-browser page,
    /// which reads exactly like a credentials failure and is not one.
    static var captureUserAgent: String {
        ChatEndpoints.defaultUserAgent
    }
}

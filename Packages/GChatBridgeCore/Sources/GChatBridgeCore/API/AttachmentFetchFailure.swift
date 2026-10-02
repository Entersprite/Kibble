import Foundation

/// Why a fetch failed, with every hop made before it did.
public struct AttachmentFetchFailure: Error, Hashable {
    public enum Reason: Sendable, Hashable {
        /// A hop redirected to Google's sign-in page: the session is not usable.
        case signInRedirect
        /// `AttachmentFetch.maxHops` requests, and the last one still redirected.
        case tooManyRedirects
        case redirectWithoutLocation
        case httpStatus(Int)
        /// The body ended before its `Content-Length`, when it stated one and
        /// no `Content-Encoding` made that the compressed size.
        case truncated(expected: Int, received: Int)
        /// A 2xx whose body is a page. Auth failure is HTTP 200 on this
        /// protocol, so this is how an unusable session can present itself.
        case htmlInsteadOfAttachment
        /// Classified by the transport, or `nil` when it could not be. Never
        /// the error itself, whose description can carry the request's URL.
        case transport(TransportFailureReason?)
    }

    /// What a refusing hop answered with, without its body or any header
    /// value: whether it is a page, how big, and which headers it set.
    public struct Refusal: Sendable, Hashable {
        public let contentType: String?
        public let bodyBytes: Int
        /// Lowercased and sorted, once each.
        public let headerNames: [String]

        public init(contentType: String?, bodyBytes: Int, headerNames: [String]) {
            self.contentType = contentType
            self.bodyBytes = bodyBytes
            self.headerNames = headerNames
        }
    }

    public let reason: Reason
    public let hops: [AttachmentHop]
    /// Set for `.httpStatus` only.
    public let refusal: Refusal?

    public init(reason: Reason, hops: [AttachmentHop], refusal: Refusal? = nil) {
        self.reason = reason
        self.hops = hops
        self.refusal = refusal
    }
}

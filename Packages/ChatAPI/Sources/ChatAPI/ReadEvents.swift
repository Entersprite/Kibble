import ChatKit
import Foundation

public struct ReadEvents: ServiceRequestPayload {
    public typealias Response = ServiceEventPage
    public static let operation = "readEvents"
    public static let requiresAccount = true
    public let cursor: ServiceCursor?
    public let limit: Int
    public let clientAttachmentID: ClientAttachmentID?

    public init(cursor: ServiceCursor?, limit: Int, clientAttachmentID: ClientAttachmentID? = nil) {
        self.cursor = cursor
        self.limit = limit
        self.clientAttachmentID = clientAttachmentID
    }
}

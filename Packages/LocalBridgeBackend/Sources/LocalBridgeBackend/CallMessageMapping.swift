import ChatKit
import GChatBridgeCore

enum CallMessageMapping {
    static func status(in annotations: [Annotation]) -> MessageCallStatus? {
        for annotation in annotations where annotation.type == .gsuiteIntegration {
            guard case let .gsuiteIntegrationMetadata(integration)? = annotation.metadata,
                  integration.clientType == 1, integration.hasCallData else { continue }
            return switch integration.callData.callStatus {
            case 1: .started
            case 2: .missed
            case 3: .ended
            case let raw: .unknown(String(raw))
            }
        }
        return nil
    }
}

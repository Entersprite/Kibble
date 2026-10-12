import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func conversationRPC(_ call: BatchExecuteCall) async throws {
        guard let context = bootstrapWiz.flatMap({ BatchExecuteContext($0) }) else {
            observeConversationRPC(call, outcome: "missingContext")
            throw ChatError.unknown("The session lacks the context required for conversation actions.")
        }
        searchRequestID += 100_000
        let request = BatchExecute.request(
            call, context: context, requestID: searchRequestID,
            endpoints: endpoints, sendsExtensionHeader: false
        )
        try Task.checkCancellation()
        let response: HTTPResponse
        do {
            response = try await PunctualClient(transport: transport, credentials: credentials).send(request)
        } catch {
            if !Task.isCancelled {
                observeConversationRPC(call, outcome: "transportFailure")
            }
            throw error
        }
        try Task.checkCancellation()
        try confirmConversationRPC(call, response: response, signed: request.headers["Authorization"] != nil)
    }

    private func confirmConversationRPC(
        _ call: BatchExecuteCall,
        response: HTTPResponse,
        signed: Bool
    ) throws {
        guard response.status == 200 else {
            observeConversationRPC(call, status: response.status, outcome: "httpFailure", signed: signed)
            throw ChatError.server(status: response.status, message: "Conversation action failed.")
        }
        let answers: [BatchExecuteAnswer]
        do {
            answers = try BatchExecute.answers(in: response.body)
        } catch {
            observeConversationRPC(call, status: response.status, outcome: "invalidFrame", signed: signed)
            throw ChatError.decoding("The service returned an invalid conversation-action response.")
        }
        guard let answer = answers.first(where: { $0.rpc == call.rpc }) else {
            observeConversationRPC(call, status: response.status, outcome: "missingRPC", signed: signed)
            throw ChatError.decoding("The service did not return the requested conversation action.")
        }
        if let code = answer.errorCode, code != 0 {
            observeConversationRPC(
                call,
                status: response.status,
                code: code,
                outcome: "serviceFailure",
                signed: signed
            )
            throw ChatError.server(
                status: response.status,
                message: "Conversation action failed (service code \(code))."
            )
        }
        guard let payload = answer.payload else {
            observeConversationRPC(call, status: response.status, outcome: "missingPayload", signed: signed)
            throw ChatError.decoding("The service did not confirm the conversation action (missing payload).")
        }
        let decoded = try? JSONSerialization.jsonObject(
            with: Data(payload.utf8),
            options: [.fragmentsAllowed]
        )
        guard decoded is [Any] else {
            let shape = Self.payloadShape(decoded)
            observeConversationRPC(
                call,
                status: response.status,
                outcome: "invalidPayload",
                shape: shape,
                signed: signed
            )
            throw ChatError
                .decoding("The service did not confirm the conversation action (payload: \(shape)).")
        }
        observeConversationRPC(call, status: response.status, outcome: "accepted", signed: signed)
    }

    private func observeConversationRPC(
        _ call: BatchExecuteCall, status: Int? = nil, code: Int? = nil, outcome: String, shape: String? = nil,
        signed: Bool? = nil
    ) {
        onConversationAction?(ConversationActionObservation(
            rpc: call.rpc, status: status, serviceCode: code, outcome: outcome, payloadShape: shape,
            hasSessionProof: signed
        ))
    }

    private static func payloadShape(_ value: Any?) -> String {
        switch value {
        case nil: "invalidJSON"
        case is NSNull: "null"
        case is [String: Any]: "object"
        case is String: "string"
        case is NSNumber: "scalar"
        default: "other"
        }
    }
}

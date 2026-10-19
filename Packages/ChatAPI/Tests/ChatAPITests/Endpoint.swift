import ChatAPI
import ChatKit
import Foundation

actor Endpoint: ServiceEndpoint {
    enum Mode: Sendable, CaseIterable {
        case normal, wrongRequest, wrongAccount, wrongVersion, malformed, hostFailure, held, large
    }

    let mode: Mode
    private(set) var requests: [ServiceRequest] = []
    private(set) var contexts: [ServiceSessionContext] = []
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var holds: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ mode: Mode = .normal) {
        self.mode = mode
    }

    func handle(_ data: Data, context: ServiceSessionContext) async throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: data)
        requests.append(request)
        contexts.append(context)
        let waiters = entered
        entered = []
        for waiter in waiters {
            waiter.resume()
        }
        if mode == .held, !released {
            await withCheckedContinuation { holds.append($0) }
        }
        switch mode {
        case .malformed: return Data("not JSON".utf8)
        case .hostFailure: throw HostFailure()
        case .large: return Data(repeating: 32, count: 4096)
        default: break
        }
        let result: ServiceResult
        switch request.operation {
        case ListAccounts.operation:
            _ = try request.decodePayload(ListAccounts.self)
            let accounts = context.accounts.map {
                AccountSummary(id: $0, selfID: Member.ID("users/self"), label: "Acme", connection: .connected)
            }
            result = try .success(ServiceCodec.value(accounts))
        case LoadConversations.operation:
            _ = try request.decodePayload(LoadConversations.self)
            let conversation = Conversation(id: Conversation.ID("space/shared"), kind: .space)
            result = try .success(ServiceCodec.value([conversation]))
        default: result = .failure(.unsupportedOperation)
        }
        return try ServiceCodec.encode(ServiceResponse(
            requestID: mode == .wrongRequest ? ServiceRequestID("foreign") : request.header.requestID,
            accountID: mode == .wrongAccount ? ConnectedAccountID("foreign") : request.header.accountID,
            result: result,
            version: mode == .wrongVersion ? .init(major: 2, minor: 0) : request.header.version
        ))
    }

    func waitForRequest() async {
        if !requests.isEmpty {
            return
        }
        await withCheckedContinuation { entered.append($0) }
    }

    func release() {
        released = true
        let waiting = holds
        holds = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

struct HostFailure: Error {}

let accountA = ConnectedAccountID("account-a")
let accountB = ConnectedAccountID("account-b")

func context(accounts: Set<ConnectedAccountID> = [accountA]) -> ServiceSessionContext {
    ServiceSessionContext(
        principalID: ServicePrincipalID("principal-a"), deviceID: ServiceDeviceID("device-a"),
        sessionID: ClientSessionID("session-a"), accounts: accounts
    )
}

func request(
    id: String = "request-1", account: ConnectedAccountID? = nil, deadline: Date? = nil
) throws -> ServiceRequest {
    let header = ServiceRequestHeader(requestID: ServiceRequestID(id), accountID: account, deadline: deadline)
    if account != nil {
        return try ServiceRequest(header: header, payload: LoadConversations())
    }
    return try ServiceRequest(header: header, payload: ListAccounts())
}

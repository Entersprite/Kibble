import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport

actor TestLinkCustody: AccountLinkCustody {
    var identity = Member.ID("new-self")
    var failAfterInstall = false
    var holdVerification = false
    private var discardFailures = 0
    private(set) var verifying = false
    private(set) var installed: Set<String> = []
    private(set) var discarded: Set<AccountLinkID> = []
    private(set) var erased: Set<String> = []
    private(set) var installs = 0

    func configure(
        identity: Member.ID? = nil,
        failAfterInstall: Bool = false,
        holdVerification: Bool = false, discardFailures: Int = 0
    ) {
        if let identity {
            self.identity = identity
        }
        self.failAfterInstall = failAfterInstall
        self.holdVerification = holdVerification
        self.discardFailures = discardFailures
    }

    func verify(_ link: AccountLinkRecord) async throws -> VerifiedLinkIdentity {
        verifying = true
        if holdVerification {
            try await Task.sleep(for: .seconds(60))
        }
        return VerifiedLinkIdentity(selfID: identity, label: "Verified account")
    }

    func install(_ link: AccountLinkRecord) throws {
        if installed.contains(link.generation) {
            return
        }
        installed.insert(link.generation)
        installs += 1
        if failAfterInstall {
            throw ServiceFailure.internalFailure
        }
    }

    func discardStaging(_ link: AccountLinkRecord) throws {
        if discardFailures > 0 {
            discardFailures -= 1
            throw ServiceFailure.internalFailure
        }
        discarded.insert(link.id)
    }

    func eraseGeneration(account: ConnectedAccountID, generation: String) {
        erased.insert(generation)
    }
}

struct LinkHarness {
    let directory: URL
    let registry: SQLiteAccountRegistry
    let custody: TestLinkCustody
    let providers: TestProviders
    let service: ChatService
    let context: ServiceSessionContext
    let transport: InProcessChatTransport

    static func make(
        records: [AccountRecord] = [],
        custody: TestLinkCustody = TestLinkCustody()
    ) async throws -> LinkHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        for record in records {
            try registry.save(record)
        }
        let providers = TestProviders()
        let service = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: directory),
            providers: providers,
            linkCustody: custody
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: ServicePrincipalID("owner"),
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("session"),
            accounts: [],
            hasAllAccountAccess: true,
            canLinkAccounts: true
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        return LinkHarness(
            directory: directory,
            registry: registry,
            custody: custody,
            providers: providers,
            service: service,
            context: context,
            transport: transport
        )
    }

    func call<P: ServiceRequestPayload>(_ payload: P, account: ConnectedAccountID? = nil) async throws -> P
        .Response {
        let revision = try account
            .flatMap { id in try registry.accounts().first { $0.id == id }?.currentRevision }
        let request = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID(UUID().uuidString),
                accountID: account,
                accountRevision: revision
            ),
            payload: payload
        )
        return try await transport.exchange(request).value(for: P.self)
    }

    static func existing() -> AccountRecord {
        AccountRecord(
            id: ConnectedAccountID("existing"),
            principalID: ServicePrincipalID("owner"),
            selfID: Member.ID("existing-self"),
            label: "Existing",
            credentialGeneration: "old-generation"
        )
    }
}

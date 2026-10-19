import ChatAPI
import ChatService
import Foundation
import LocalBridgeBackend
import MacHost
import Testing

struct LocalAccountCustodyTests {
    private final class Secrets: SecretStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        var isEmpty: Bool {
            lock.withLock { items.isEmpty }
        }

        func read(account: String) -> Data? {
            lock.withLock { items[account] }
        }

        func write(_ data: Data, account: String) {
            lock.withLock { items[account] = data }
        }

        func delete(account: String) {
            lock.withLock { items[account] = nil }
        }

        var count: Int {
            lock.withLock { items.count }
        }
    }

    private func link(_ id: String) -> AccountLinkRecord {
        AccountLinkRecord(
            id: AccountLinkID(id),
            operationID: ServiceOperationID(id),
            principalID: ServicePrincipalID("owner"),
            deviceID: ServiceDeviceID("device"),
            targetAccountID: nil,
            accountID: ConnectedAccountID("account"),
            generation: "generation",
            previousGeneration: nil,
            expiresAt: .distantFuture
        )
    }

    private func capture() -> CookieCapture {
        CookieCapture(
            cookies: [CapturedCookie(
                name: "SID",
                value: "synthetic",
                domain: ".google.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: true,
                expiresAt: nil
            )],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pageURL: "https://chat.google.com/",
            pageTitle: "Chat"
        )
    }

    @Test func stagingSlotsAndServiceInstancesAreIsolatedAndDiscardFencesRetainedViews() async throws {
        let secrets = Secrets()
        let first = try LocalAccountCustody(storage: secrets, instanceID: ServiceInstanceID("local"))
        let second = try LocalAccountCustody(storage: secrets, instanceID: ServiceInstanceID("other-host"))
        let firstCapture = try await first.captureStore(for: link("a"))
        let secondCapture = try await first.captureStore(for: link("b"))
        let other = try await second.captureStore(for: link("a"))
        #expect(try await capture().save(to: firstCapture))
        #expect(try await capture().save(to: secondCapture))
        #expect(try await capture().save(to: other))
        #expect(secrets.count == 3)
        try await first.discardStaging(link("a"))
        #expect(secrets.count == 2)
        await #expect(throws: SessionCustodyError.sessionChanged) {
            try await capture().save(to: firstCapture)
        }
        #expect(try await secondCapture.summary(at: .distantPast) != nil)
        #expect(try await other.summary(at: .distantPast) != nil)
        try await first.discardStaging(link("a"))
        #expect(secrets.count == 2)
    }

    @Test func emptyOrOversizedNamespaceIsRefusedBeforeASecretRead() throws {
        let secrets = Secrets()
        #expect(throws: ServiceFailure.invalidRequest) { try LocalAccountCustody(
            storage: secrets,
            instanceID: ServiceInstanceID("")
        ) }
        #expect(throws: ServiceFailure.invalidRequest) {
            try LocalAccountCustody(
                storage: secrets,
                instanceID: ServiceInstanceID(String(repeating: "x", count: 121))
            )
        }
        #expect(secrets.isEmpty)
    }
}

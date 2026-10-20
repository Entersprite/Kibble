import AppCore
import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import MacHost

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ServiceNotificationDeliveryTests {
    @Test func replayAndRecreatedHostShareDurableIdentityButAccountsRemainSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let center = ServiceNotificationCenterFixture()
        let host = make(center, directory)
        try await host.deliver(frame(account: "first"))
        try await host.deliver(frame(account: "first"))
        try await make(center, directory).deliver(frame(account: "first"))
        #expect(await center.posts.count == 1)
        try await host.deliver(frame(account: "second"))
        #expect(await center.posts.count == 2)
        let scopes = await center.posts
        #expect(Set(scopes.map(\.account)) == [.init("first"), .init("second")])
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        try Data("invalid identities".utf8).write(to: #require(files.first), options: .atomic)
        let identities = FileNotificationDeliveryIdentities(directory: directory)
        #expect(throws: (any Error).self) {
            for scope in scopes {
                _ = try identities.claim("another", scope: scope)
            }
        }
    }

    @Test func foreignServiceAndUnknownOperationAreRefusedWithTheirPayloadPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = make(ServiceNotificationCenterFixture(), directory)
        let unknown = HostNotificationFrame(
            service: .init("service"),
            account: .init("first"),
            revision: .init("revision"),
            deliveryID: "unknown",
            operation: "future",
            payload: .object(["nested": .object(["value": .string("retained")])])
        )
        let decoded = try ServiceCodec.decode(HostNotificationFrame.self, from: ServiceCodec.encode(unknown))
        #expect(decoded == unknown)
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await host.deliver(ServiceCodec.encode(decoded))
        }
        let foreign = HostNotificationFrame(
            service: .init("foreign"),
            account: unknown.account,
            revision: unknown.revision,
            deliveryID: "foreign",
            operation: "reset",
            payload: .object([:])
        )
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await host.deliver(ServiceCodec.encode(foreign))
        }
    }

    private func make(
        _ center: ServiceNotificationCenterFixture,
        _ directory: URL
    ) -> LocalServiceNotificationHost {
        LocalServiceNotificationHost(
            service: .init("service"),
            device: .init("device"),
            center: center,
            directory: directory
        ) { _ in .init() }
    }

    private func frame(account: String) throws -> Data {
        let message = Message(
            id: .init("same-message"),
            conversationID: .init("same-room"),
            threadID: .init("thread"),
            sender: .init("peer"),
            text: "A new message",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return try ServiceCodec.encode(HostNotificationFrame(
            service: .init("service"), account: .init(account), revision: .init("revision"),
            deliveryID: "same-delivery", operation: "post", payload: ServiceCodec.value(HostNotificationPost(
                message: message, conversation: Conversation(
                    id: message.conversationID,
                    kind: .space,
                    title: "Room"
                ),
                members: [], me: .init("self"), accountLabel: account, isPassive: false,
                playsSound: true, showsPreview: true, offersMarkRead: true
            ))
        ))
    }
}

private actor ServiceNotificationCenterFixture: AccountNotificationDelivering {
    nonisolated var accountResponses: AsyncStream<AccountNotificationResponse> {
        AsyncStream { $0.finish() }
    }

    private(set) var posts: [AccountNotificationScope] = []
    func requestAuthorization() {}
    func post(_ notification: MessageNotification, scope: AccountNotificationScope) {
        posts.append(scope)
    }

    func withdraw(
        in conversation: Conversation.ID,
        coveredBy position: Date,
        scope: AccountNotificationScope
    ) {}
    func withdrawAll(in scope: AccountNotificationScope) {}
    func retainNotifications(in scopes: Set<AccountNotificationScope>) {}
}

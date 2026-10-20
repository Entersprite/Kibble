import AppCore
import ChatAPI
import ChatService
import CryptoKit
import Foundation

/// Native delivery for the service's independently owned outbox worker.
@MainActor
final class LocalServiceNotificationHost: ServiceNotificationHost {
    nonisolated let deviceID: ServiceDeviceID
    private let service: ServiceInstanceID
    private let center: any AccountNotificationDelivering
    private let identities: FileNotificationDeliveryIdentities
    private let visibility: @MainActor (ConnectedAccountID) -> NotificationDeviceState
    private var authorization: Task<Void, Never>?

    init(
        service: ServiceInstanceID, device: ServiceDeviceID, center: any AccountNotificationDelivering,
        directory: URL, visibility: @escaping @MainActor (ConnectedAccountID) -> NotificationDeviceState
    ) {
        self.service = service; deviceID = device; self.center = center; self.visibility = visibility
        identities = FileNotificationDeliveryIdentities(directory: directory)
    }

    func state(account: ConnectedAccountID) -> NotificationDeviceState {
        visibility(account)
    }

    func deliver(_ bytes: Data) async throws {
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        let frame = try ServiceCodec.decode(HostNotificationFrame.self, from: bytes)
        guard frame.service == service, !frame.deliveryID.isEmpty, frame.deliveryID.utf8.count <= 256 else {
            throw ServiceFailure.notAuthorized
        }
        let scope = AccountNotificationScope(
            service: service,
            account: frame.account,
            revision: frame.revision
        )
        switch frame.operation {
        case "post":
            let post = try ServiceCodec.decode(HostNotificationPost.self, from: frame.payload)
            guard post.message.conversationID == post.conversation.id, post.members.count <= 16 else {
                throw ServiceFailure.invalidResponse
            }
            if authorization == nil {
                authorization = Task { [center] in await center.requestAuthorization() }
            }
            await authorization?.value
            try Task.checkCancellation()
            // Persist before handing off to the OS. A crash in that interval
            // may miss an alert; replay cannot ring twice after an uncertain add.
            guard try identities.claim(frame.deliveryID, scope: scope) else { return }
            await center.post(HostNotificationRenderer.render(post), scope: scope)
        case "withdraw":
            let value = try ServiceCodec.decode(HostNotificationWithdrawal.self, from: frame.payload)
            await center.withdraw(in: value.conversation, coveredBy: value.upTo, scope: scope)
        case "reset": await center.withdrawAll(in: scope)
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}

@MainActor
final class FileNotificationDeliveryIdentities {
    private let directory: URL
    init(directory: URL) {
        self.directory = directory
    }

    func claim(_ id: String, scope: AccountNotificationScope) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = try SHA256.hash(data: ServiceCodec.encode(scope)).map { String(format: "%02x", $0) }
            .joined()
        let file = directory.appendingPathComponent(digest + ".json")
        var recent: [String]
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 2 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
            recent = try ServiceCodec.decode([String].self, from: data)
            guard recent.count <= 4096 else { throw ServiceFailure.frameTooLarge }
        } catch CocoaError.fileReadNoSuchFile { recent = [] }
        guard !recent.contains(id) else { return false }
        recent.append(id)
        if recent.count > 4096 {
            recent.removeFirst(recent.count - 4096)
        }
        try ServiceCodec.encode(recent).write(to: file, options: .atomic)
        return true
    }
}

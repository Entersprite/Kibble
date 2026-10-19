import Foundation
@testable import LocalBridgeBackend

struct AbsentTestSecrets: SecretStorage {
    func read(account _: String) -> Data? {
        nil
    }

    func write(_: Data, account _: String) throws {
        throw SecretStorageUnavailable(status: -1)
    }

    func delete(account _: String) {}
}

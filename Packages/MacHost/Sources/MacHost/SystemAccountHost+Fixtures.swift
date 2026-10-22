import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import FixtureBackend
import Foundation

extension SystemAccountHost {
    func seed(_ registry: SQLiteAccountRegistry, directory: URL) throws {
        let marker = directory.appendingPathComponent("fixture.seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        if try registry.accounts().isEmpty {
            for (id, identity, label) in [
                ("personal", Acme.alex, "Personal demo"), ("studio", Acme.maya, "Studio demo")
            ] {
                try registry.save(AccountRecord(
                    id: ConnectedAccountID(id), principalID: ServicePrincipalID("fixture-owner"),
                    selfID: identity, label: label, credentialGeneration: "fixture"
                ))
            }
        }
        try Data().write(to: marker, options: .atomic)
    }
}

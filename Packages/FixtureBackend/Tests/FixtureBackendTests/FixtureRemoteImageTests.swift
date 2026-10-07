import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The fixture serves its one picture for `acme.example` only, so a demo
/// card never reaches the network (links spec §7.6).
struct FixtureRemoteImageTests {
    @Test func theFixtureServesAcmeImagesOnly() async throws {
        let backend = FakeBackend(world: .acme)
        #expect(try await backend
            .remoteImage(#require(URL(string: "https://media.acme.example/a.png"))) == FixtureImage.png)
        await #expect(throws: (any Error).self) {
            _ = try await backend.remoteImage(#require(URL(string: "https://elsewhere.example/a.png")))
        }
    }

    @Test func withoutTheCapabilityItRefuses() async throws {
        let backend = FakeBackend(world: .acme, capabilities: Capabilities())
        await #expect(throws: ChatError.unsupported(capability: "canFetchRemoteImages")) {
            _ = try await backend.remoteImage(#require(URL(string: "https://media.acme.example/a.png")))
        }
    }
}

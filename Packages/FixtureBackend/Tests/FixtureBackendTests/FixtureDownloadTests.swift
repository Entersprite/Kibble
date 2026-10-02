import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// `FakeBackend.downloadAttachment(_:to:progress:)`: a file is written to
/// disk deterministically from `FixtureFile.bytes`, with progress reported in
/// four fixed steps. No clock and no wait: the fixture package reads no clock,
/// so every step is reported immediately, which is what keeps a test of this
/// deterministic.
@Suite(.timeLimit(.minutes(1)))
struct FixtureDownloadTests {
    static let pdf = Attachment(
        id: "fixture-upload:map-file", name: "MAP update - Tuesday.pdf", contentType: "application/pdf"
    )

    static func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fixture-download-\(UUID().uuidString)")
    }

    @Test("a file in the world is written to the destination, with progress ending at its size")
    func writesTheFile() async throws {
        let backend = FakeBackend(world: .acme)
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let seen = ProgressLog()
        try await backend.downloadAttachment(Self.pdf, to: destination) { seen.append($0) }
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == FixtureFile.bytes(for: Self.pdf))
        #expect(seen.values.last == AttachmentProgress(bytesReceived: bytes.count, totalBytes: bytes.count))
    }

    @Test("an attachment the world does not hold is refused, and nothing is written")
    func refusesAStranger() async throws {
        let backend = FakeBackend(world: .acme)
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let stranger = Attachment(id: "nope", name: "x.pdf", contentType: "application/pdf")
        await #expect(throws: ChatError.self) {
            try await backend.downloadAttachment(stranger, to: destination) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test("without canDownloadFiles the fixture refuses like a backend that cannot")
    func refusesWithoutTheCapability() async throws {
        let backend = FakeBackend(world: .acme, capabilities: Capabilities())
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        await #expect(throws: ChatError.unsupported(capability: "canDownloadFiles")) {
            try await backend.downloadAttachment(Self.pdf, to: destination) { _ in }
        }
    }

    @Test("an existing destination is refused rather than overwritten")
    func refusesAnExistingDestination() async throws {
        let backend = FakeBackend(world: .acme)
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("old".utf8).write(to: destination, options: .atomic)
        await #expect(throws: ChatError.self) {
            try await backend.downloadAttachment(Self.pdf, to: destination) { _ in }
        }
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(contents == "old")
    }
}

/// Helper for tracking progress callbacks.
final class ProgressLog: @unchecked Sendable {
    private var lock = NSLock()
    private var _values: [AttachmentProgress] = []

    var values: [AttachmentProgress] {
        lock.withLock { _values }
    }

    func append(_ progress: AttachmentProgress) {
        lock.withLock { _values.append(progress) }
    }
}

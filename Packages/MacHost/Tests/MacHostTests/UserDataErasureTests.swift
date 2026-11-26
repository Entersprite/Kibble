import Foundation
import Testing
@testable import MacHost

struct UserDataErasureTests {
    @MainActor
    @Test func aFailedWriterDrainPreservesFilesAndPendingIntentUntilRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let erasure = UserDataErasure(directory: root)
        try erasure.begin()
        let data = root.appendingPathComponent("drafts")
        try Data("unsent".utf8).write(to: data)
        var events: [String] = []
        await #expect(throws: CocoaError.self) {
            try await erasure.run(
                stoppingWriters: {
                    events.append("stop")
                    throw CocoaError(.fileWriteUnknown)
                },
                erasingNativeData: { events.append("native") },
                clearingPreferences: { events.append("preferences") }
            )
        }
        #expect(events == ["stop"])
        #expect(erasure.isPending)
        #expect(FileManager.default.fileExists(atPath: data.path))
        try await erasure.run(stoppingWriters: { events.append("drained") }, erasingNativeData: {
            #expect(FileManager.default.fileExists(atPath: data.path))
            events.append("native")
        }, clearingPreferences: {
            #expect(!FileManager.default.fileExists(atPath: data.path))
            events.append("preferences")
        })
        #expect(events == ["stop", "drained", "native", "preferences"])
        #expect(!erasure.isPending)
    }

    @Test func clearsOnlyKnownTemporaryStagingAndPreservesExternalTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("temporary")
        let external = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let kept = external.appendingPathComponent("kept.txt")
        try Data("keep".utf8).write(to: kept)
        try FileManager.default.createSymbolicLink(
            at: temporary.appendingPathComponent("kibble-downloads"),
            withDestinationURL: external
        )
        try Data().write(to: temporary.appendingPathComponent("kibble-replace-" + UUID().uuidString))
        let unrelated = temporary.appendingPathComponent("unrelated")
        try Data().write(to: unrelated)
        try UserDataErasure.eraseTemporaryFiles(in: temporary)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == ["unrelated"])
    }

    @Test func removesOwnedStateButPreservesExternalFilesAndLockInodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("Kibble")
        let external = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let document = external.appendingPathComponent("personal.txt")
        try Data("retained".utf8).write(to: document)
        let erasure = UserDataErasure(directory: owned)
        try erasure.begin()
        let accounts = owned.appendingPathComponent("Accounts")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        let lock = accounts.appendingPathComponent("service.lock")
        try Data().write(to: lock)
        let inode = try FileManager.default
            .attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber
        try Data("private".utf8).write(to: accounts.appendingPathComponent("registry.sqlite"))
        try FileManager.default.createSymbolicLink(
            at: owned.appendingPathComponent("linked-downloads"),
            withDestinationURL: external
        )
        try erasure.eraseFiles()
        #expect(erasure.isPending)
        #expect(try Data(contentsOf: document) == Data("retained".utf8))
        #expect(!FileManager.default
            .fileExists(atPath: accounts.appendingPathComponent("registry.sqlite").path))
        #expect(try FileManager.default
            .attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber == inode)
        try erasure.finish()
        #expect(!erasure.isPending)
    }

    @Test func refusesLinkedRootsAndKeepsPendingIntentAfterFailedCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        #expect(throws: (any Error).self) { try UserDataErasure(directory: linked).begin() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        let erasure = UserDataErasure(directory: root.appendingPathComponent("owned"))
        try erasure.begin()
        let accounts = erasure.directory.appendingPathComponent("Accounts")
        try FileManager.default.createSymbolicLink(at: accounts, withDestinationURL: external)
        #expect(throws: (any Error).self) { try erasure.eraseFiles() }
        #expect(erasure.isPending)
        try FileManager.default.removeItem(at: accounts)
        try erasure.eraseFiles()
        try erasure.finish()
        #expect(!erasure.isPending)
    }
}

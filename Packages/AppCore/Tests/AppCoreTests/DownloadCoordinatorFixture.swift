import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// The backend's half of a download, scripted: records every destination it
/// was handed, keeps the progress callback, can hold a transfer until the test
/// releases it, and writes "PDF" unless told to throw. A cancelled transfer
/// throws `ChatError.transport`, as the real backend does.
actor DownloadScript {
    private(set) var destinations: [URL] = []
    /// Every transfer's progress callback, in the order the transfers began.
    private(set) var progressCallbacks: [@Sendable (AttachmentProgress) -> Void] = []
    private var failure: ChatError?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int {
        held.count
    }

    var progress: (@Sendable (AttachmentProgress) -> Void)? {
        progressCallbacks.last
    }

    func hold() {
        holding = true
    }

    func fail(with error: ChatError) {
        failure = error
    }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    /// Lets the oldest held transfer go and keeps holding the rest.
    func releaseOldest() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func run(
        _ destination: URL,
        _ progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        destinations.append(destination)
        progressCallbacks.append(progress)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if Task.isCancelled {
            throw ChatError.transport("cancelled")
        }
        if let failure {
            throw failure
        }
        try Data("PDF".utf8).write(to: destination)
    }
}

@MainActor
struct DownloadFixture {
    static let report = ChatKit.Attachment(
        id: "token-1",
        name: "report.pdf",
        contentType: "application/pdf",
        byteSize: 3
    )

    let root: URL
    let staging: URL
    let folder: URL
    let platform: FakeDownloadPlatform
    let script = DownloadScript()
    let coordinator: DownloadCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "download-coordinator-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        staging = root.appending(path: "staging", directoryHint: .isDirectory)
        folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        platform = FakeDownloadPlatform(folder: folder)
        let script = script
        coordinator = DownloadCoordinator(staging: staging, platform: platform) { _, destination, progress in
            try await script.run(destination, progress)
        }
    }

    var state: AttachmentDownloadState? {
        coordinator.states[Self.report.id]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?
            .sorted() ?? []
    }

    func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    /// Starts nothing; waits for whatever transfer is running to end.
    func finish() async throws {
        let task = try #require(coordinator.task(for: Self.report))
        await task.value
    }

    func downloadToDone() async throws {
        coordinator.start(Self.report)
        try await finish()
        try #require(state == .done)
    }

    func waitUntilHeld(_ count: Int = 1) async throws {
        let script = script
        _ = await eventually { await script.heldCount == count }
        try #require(await script.heldCount == count)
    }
}

import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// The download coordinator, as `AppEnvironment` builds it per session and
/// offers it to the scene: the chip's actions exist only when the backend can
/// download files, a started download reaches the scene and the folder, and
/// sign-out cancels what is running and takes the coordinator with it.
@MainActor
struct AppEnvironmentDownloadsTests {
    private static let map = ChatKit.Attachment(
        id: "fixture-upload:map-file",
        name: "map.pdf",
        contentType: "application/pdf",
        byteSize: 3
    )

    private func running(canDownload: Bool) async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(
                canSendMessages: true, canFetchAttachments: true, canDownloadFiles: canDownload
            )
        )
        try FileManager.default.createDirectory(
            at: services.downloadDirectory,
            withIntermediateDirectories: true
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return (environment, services)
        }
        return (environment, services)
    }

    private func cleanUp(_ services: FakeLaunchServices) {
        try? FileManager.default.removeItem(at: services.downloadDirectory)
        try? FileManager.default.removeItem(at: services.attachmentDirectory)
    }

    private func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?
            .sorted() ?? []
    }

    @Test func aStartedDownloadReachesTheSceneAndTheFolder() async throws {
        let (environment, services) = try await running(canDownload: true)
        defer { cleanUp(services) }
        let files = try #require(environment.actions.attachmentFiles)

        files.download(Self.map)
        let finished = await eventually { environment.sceneState.downloads[Self.map.id] == .done }
        try #require(finished, "\(String(describing: environment.sceneState.downloads))")

        let placed = services.downloadPlatformFake.folder.url.appending(path: "map.pdf")
        #expect(try Data(contentsOf: placed) == Data("PDF".utf8))
    }

    @Test func withoutTheCapabilityNoFileActionIsOffered() async throws {
        let services = try FakeLaunchServices(backendCapabilities: Capabilities(canFetchAttachments: true))
        defer { cleanUp(services) }
        let environment = AppEnvironment(services: services)
        await environment.start()
        // Positive control: a running session, so `nil` is the capability's doing.
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return
        }
        #expect(environment.actions.loadAttachment != nil)
        #expect(environment.actions.attachmentFiles == nil)
    }

    @Test func signingOutCancelsARunningDownloadAndDropsTheCoordinator() async throws {
        let (environment, services) = try await running(canDownload: true)
        defer { cleanUp(services) }
        services.backend.holdDownloads()
        let files = try #require(environment.actions.attachmentFiles)
        files.download(Self.map)
        let entered = await eventually { services.backend.downloadsEntered == 1 }
        try #require(entered)
        // Positive control: a transfer the scene shows as running.
        guard case .downloading = environment.sceneState.downloads[Self.map.id] else {
            Issue.record("expected .downloading, got \(String(describing: environment.sceneState.downloads))")
            return
        }

        await environment.signOut()

        #expect(environment.downloads == nil)
        #expect(environment.actions.attachmentFiles == nil)
        #expect(environment.sceneState.downloads.isEmpty)
        let cancelled = await eventually { services.backend.downloadsCancelled == 1 }
        #expect(cancelled)
        #expect(names(in: services.downloadDirectory).isEmpty)
    }

    /// A chip still on screen during sign-out holds the actions it was given.
    @Test func anActionHeldAcrossSignOutStartsNothing() async throws {
        let (environment, services) = try await running(canDownload: true)
        defer { cleanUp(services) }
        let files = try #require(environment.actions.attachmentFiles)
        await environment.signOut()

        files.download(Self.map)
        // Bounded, and expected to time out: nothing may reach the backend.
        let entered = await eventually(timeout: .milliseconds(200)) { services.backend.downloadsEntered > 0 }
        #expect(!entered)
        #expect(environment.sceneState.downloads.isEmpty)
    }

    /// Settings opens before any session: the pane reads the platform's folder.
    @Test func withNoSessionSettingsShowThePlatformsFolder() throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        let state = environment.downloadSettingsState
        #expect(state.folderPath == services.downloadDirectory.resolvingSymlinksInPath()
            .path(percentEncoded: false))
        #expect(state.isDefault)
        #expect(state.notice == nil)
    }

    /// The sandbox's Downloads is a symlink inside the container: the pane
    /// shows where it leads, and the folder written to is left alone.
    @Test func aSymlinkedFolderShowsItsResolvedPath() throws {
        let services = try FakeLaunchServices()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "download-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Real Downloads", directoryHint: .isDirectory)
        let link = root.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        services.downloadPlatformFake.folder = DownloadFolder(url: link, isDefault: true)
        let environment = AppEnvironment(services: services)

        let state = environment.downloadSettingsState

        let resolved = target.resolvingSymlinksInPath().path(percentEncoded: false)
        // Positive control: the link and its target really are different paths.
        try #require(link.path(percentEncoded: false) != resolved)
        #expect(state.folderPath == resolved)
        #expect(state.folderName == "Real Downloads")
        #expect(services.downloadPlatformFake.folder.url == link)
    }
}

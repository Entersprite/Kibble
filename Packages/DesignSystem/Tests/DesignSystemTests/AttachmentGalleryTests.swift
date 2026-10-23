import ChatKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DesignSystem

/// Quick Look's pages for one message (`AttachmentGallery`), the file a drag
/// or a share hands over (`AttachmentTransfer`), and which pictures animate
/// (`AnimatedPicture.animates`).
@MainActor
struct AttachmentGalleryTests {
    private static let photo = ChatKit.Attachment(id: "p-1", name: "photo.png", contentType: "image/png")
    private static let chart = ChatKit.Attachment(id: "p-2", name: "chart.jpg", contentType: "image/jpeg")
    private static let report = ChatKit.Attachment(
        id: "f-1",
        name: "report.pdf",
        contentType: "application/pdf"
    )

    @MainActor
    private final class Resolver {
        var asked: [String] = []
        var failing: Set<String> = []

        func resolve(_ attachment: ChatKit.Attachment) async throws -> URL {
            asked.append(attachment.id)
            if failing.contains(attachment.id) {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: "/tmp/\(attachment.name)")
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theClickedPictureOpensFirstAndTheOthersJoinInOrder() async {
        let gallery = AttachmentGallery()
        let resolver = Resolver()
        gallery.open(
            Self.chart, pictures: [Self.photo, Self.chart], documents: [Self.report],
            resolve: resolver.resolve, placed: { _ in URL(fileURLWithPath: "/tmp/report.pdf") }
        )
        #expect(gallery.opening == ["p-2"])
        #expect(await eventually { gallery.items.count == 3 })
        #expect(resolver.asked == ["p-2", "p-1"])
        #expect(gallery.selection?.lastPathComponent == "chart.jpg")
        #expect(gallery.items.map(\.lastPathComponent) == ["photo.png", "chart.jpg", "report.pdf"])
        #expect(gallery.opening.isEmpty)
    }

    @Test func openingAgainFetchesNothingTwice() async {
        let gallery = AttachmentGallery()
        let resolver = Resolver()
        gallery.open(
            Self.photo,
            pictures: [Self.photo, Self.chart],
            documents: [],
            resolve: resolver.resolve,
            placed: nil
        )
        #expect(await eventually { gallery.items.count == 2 })
        gallery.selection = nil
        gallery.open(
            Self.chart,
            pictures: [Self.photo, Self.chart],
            documents: [],
            resolve: resolver.resolve,
            placed: nil
        )
        #expect(gallery.selection?.lastPathComponent == "chart.jpg")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(resolver.asked == ["p-1", "p-2"])
    }

    @Test func aPictureThatCannotOpenSaysSo() async {
        let gallery = AttachmentGallery()
        let resolver = Resolver()
        resolver.failing = ["p-1"]
        gallery.open(
            Self.photo,
            pictures: [Self.photo],
            documents: [],
            resolve: resolver.resolve,
            placed: nil
        )
        #expect(await eventually { gallery.failed == ["p-1"] })
        #expect(gallery.selection == nil)
        #expect(gallery.opening.isEmpty)
    }

    /// A finished download opens at once, from where the host placed it;
    /// one that has gone opens nothing.
    @Test func aDownloadedFileOpensWithoutAFetch() {
        let gallery = AttachmentGallery()
        gallery.open(
            Self.report, pictures: [], documents: [Self.report], resolve: nil,
            placed: { _ in URL(fileURLWithPath: "/tmp/report.pdf") }
        )
        #expect(gallery.selection?.lastPathComponent == "report.pdf")
        let gone = AttachmentGallery()
        gone.open(Self.report, pictures: [], documents: [Self.report], resolve: nil, placed: { _ in nil })
        #expect(gone.selection == nil)
    }

    @Test func aTransferIsOfferedAsItsOwnTypeAndExportsTheHostsFile() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "transfer-\(UUID().uuidString).pdf")
        try Data("PDF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transfer = AttachmentTransfer(attachment: Self.report) { file }
        #expect(transfer.contentType == .pdf)
        #expect(transfer.name == "report.pdf")
        #expect(transfer.exportedContentTypes().first == .pdf)
        #expect(try await transfer.exported(as: .pdf) == Data("PDF".utf8))
        let unknown = ChatKit.Attachment(
            id: "x",
            name: "notes.zzz",
            contentType: "application/x-unknown-kind"
        )
        #expect(AttachmentTransfer.type(of: unknown) == .data)
        #expect(AttachmentTransfer(attachment: unknown) { file }.exportedContentTypes() == [.data])
    }

    private static func gif(frames: Int, side: Int) throws -> Data {
        try TestGIF.make(frames: frames, side: side)
    }

    @Test func onlyASmallManyFrameAnimationPlays() throws {
        #expect(try AnimatedPicture.animates(Self.gif(frames: 3, side: 32)))
        #expect(try !AnimatedPicture.animates(Self.gif(frames: 1, side: 32)), "a still GIF")
        #expect(
            try !AnimatedPicture.animates(Self.gif(frames: 2, side: 1200)),
            "a frame too large to decode each time"
        )
        #expect(!AnimatedPicture.animates(Data("not an image".utf8)))
    }
}

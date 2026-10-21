import ChatKit
import CoreGraphics
import CoreTransferable
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// One message's pictures and downloaded files as local files, for Quick Look
/// to page through (`quickLookPreview(_:in:)`). DesignSystem fetches nothing:
/// a picture's file comes from the host's `openAttachment`, a finished
/// download's from `AttachmentFileActions.finishedFile`.
///
/// A picture's original is asked for only when the person opens one, the one
/// they clicked first; the message's other pictures follow one at a time and
/// join the pages as each arrives, so opening one picture never waits for
/// the others.
@MainActor
@Observable
final class AttachmentGallery {
    /// Every picture and file the message shows, in the order it draws them.
    private(set) var order: [String] = []
    private(set) var files: [String: URL] = [:]
    /// Pictures whose original is being fetched for the person's click, and
    /// those whose fetch failed: what the picture draws over itself.
    private(set) var opening: Set<String> = []
    private(set) var failed: Set<String> = []
    var selection: URL?
    /// Whether the other pictures are being fetched, so a second open does
    /// not fetch them twice.
    private var filling = false

    /// The pages: every file known so far, in the message's order.
    var items: [URL] {
        order.compactMap { files[$0] }
    }

    /// Opens `target` in Quick Look with the message's other pictures and
    /// downloaded files as pages. `pictures` and `documents` are in drawing
    /// order; `placed` answers for a finished download, `resolve` for a
    /// picture. Asked from the click, so the file checks `placed` makes never
    /// run while a view is drawn.
    func open(
        _ target: Attachment, pictures: [Attachment], documents: [Attachment],
        resolve: ((Attachment) async throws -> URL)?, placed: ((Attachment) -> URL?)?
    ) {
        order = (pictures + documents).map(\.id)
        for document in documents {
            files[document.id] = placed?(document)
        }
        if let file = files[target.id] {
            failed.remove(target.id)
            selection = file
        }
        guard let resolve, pictures.contains(where: { $0.id == target.id }), !opening.contains(target.id)
        else { return }
        let needsTarget = files[target.id] == nil
        if needsTarget {
            opening.insert(target.id)
            failed.remove(target.id)
        }
        Task { [weak self] in
            if needsTarget {
                do {
                    let file = try await resolve(target)
                    self?.files[target.id] = file
                    self?.opening.remove(target.id)
                    self?.selection = file
                } catch {
                    self?.opening.remove(target.id)
                    self?.failed.insert(target.id)
                    return
                }
            }
            await self?.fill(pictures, resolve: resolve)
        }
    }

    private func fill(_ pictures: [Attachment], resolve: (Attachment) async throws -> URL) async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        for picture in pictures where files[picture.id] == nil {
            guard let file = try? await resolve(picture) else { continue }
            files[picture.id] = file
        }
    }
}

/// An attachment's file, handed over only when a drop or a share asks for
/// it: the host makes the local copy, and the system copies it from there
/// (`SentTransferredFile` without access to the original).
struct AttachmentTransfer: Transferable {
    let name: String
    let contentType: UTType
    let file: @MainActor @Sendable () async throws -> URL

    init(attachment: Attachment, file: @escaping @MainActor @Sendable () async throws -> URL) {
        name = AttachmentLayout.label(for: attachment)
        contentType = Self.type(of: attachment)
        self.file = file
    }

    /// The attachment's declared type, or plain data for one the system does
    /// not know (it answers an unknown MIME type with a dynamic type rather
    /// than nothing): a receiver that wants a picture still gets the right
    /// type.
    static func type(of attachment: Attachment) -> UTType {
        guard let type = UTType(mimeType: attachment.contentType.lowercased()), !type.isDynamic else {
            return .data
        }
        return type
    }

    /// The concrete types a receiver is offered by name; anything else goes
    /// out as data with its file name, which Finder and Mail both take.
    static let offeredTypes: [UTType] = [.png, .jpeg, .gif, .heic, .tiff, .webP, .bmp, .pdf]

    static var transferRepresentation: some TransferRepresentation {
        offered(.png)
        offered(.jpeg)
        offered(.gif)
        offered(.heic)
        offered(.tiff)
        offered(.webP)
        offered(.bmp)
        offered(.pdf)
        FileRepresentation(exportedContentType: .data) { try await $0.sent() }
            .suggestedFileName { $0.name }
    }

    private static func offered(_ type: UTType) -> some TransferRepresentation<Self> {
        FileRepresentation(exportedContentType: type) { try await $0.sent() }
            .exportingCondition { $0.contentType.conforms(to: type) }
            .suggestedFileName { $0.name }
    }

    private func sent() async throws -> SentTransferredFile {
        try await SentTransferredFile(file())
    }
}

/// Copy Image, on both platforms: the original file when the host has one,
/// else the picture already on screen.
@MainActor
enum ImagePasteboard {
    static func copy(fileAt url: URL) {
        #if os(macOS)
            guard let image = NSImage(contentsOf: url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        #else
            UIPasteboard.general.image = UIImage(contentsOfFile: url.path(percentEncoded: false))
        #endif
    }

    static func copy(_ image: CGImage) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        #else
            UIPasteboard.general.image = UIImage(cgImage: image)
        #endif
    }
}

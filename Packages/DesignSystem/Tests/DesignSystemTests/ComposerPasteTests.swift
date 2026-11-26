#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    import UniformTypeIdentifiers
    @testable import DesignSystem

    /// Pasting into the composer, through AppKit's own choice of type: files
    /// and pictures are staged while the composer can stage them, and
    /// everything else is the text view's paste, exactly as before. Each test
    /// uses a private pasteboard, never the person's clipboard.
    @MainActor
    struct ComposerPasteTests {
        @MainActor
        final class Box {
            var draft = ComposerDraft()
            var files: [[URL]] = []
            var images: [ComposerPastedImage] = []
        }

        private func field(_ box: Box, staging: Bool = true, images: Bool = true) -> NSTextView {
            let representable = ComposerTextView(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                anchorX: .constant(0),
                listOpen: false,
                focusRequest: 0,
                onKey: { _ in },
                onSubmit: {},
                paste: staging ? ComposerPaste(
                    files: { box.files.append($0) },
                    image: images ? { box.images.append($0) } : nil
                ) : nil
            )
            let coordinator = representable.makeCoordinator()
            let scroll = ComposerScrollView.make(spelling: ComposerSpelling(defaults: Self.scratchDefaults()))
            scroll.textView.delegate = coordinator
            (scroll.textView as? ComposerNSTextView)?.paste = representable.paste
            // The coordinator is the delegate, which AppKit holds weakly.
            Self.kept.append(coordinator)
            return scroll.textView
        }

        private static var kept: [AnyObject] = []

        private static func scratchDefaults() -> UserDefaults {
            UserDefaults(suiteName: "composer-paste-\(UUID().uuidString)") ?? .standard
        }

        private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("kibble-composer-test-\(UUID().uuidString)"))
            board.clearContents()
            fill(board)
            return board
        }

        private static let file = URL(fileURLWithPath: "/tmp/composer-paste/notes.txt")

        /// What Finder puts on the pasteboard for a copied file: its URL, and
        /// its name as text.
        private func copiedInFinder(_ board: NSPasteboard) {
            board.declareTypes([.fileURL, .string], owner: nil)
            board.setString(Self.file.absoluteString, forType: .fileURL)
            board.setString(Self.file.lastPathComponent, forType: .string)
        }

        private static func png() throws -> Data {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            return try #require(rep.representation(using: .png, properties: [:]))
        }

        @Test func aCopiedFileIsStagedNotTypedAsItsName() {
            let box = Box()
            let view = field(box)
            let board = pasteboard(copiedInFinder)
            defer { board.releaseGlobally() }

            #expect(view.readSelection(from: board))

            #expect(box.files == [[Self.file]])
            #expect(view.string.isEmpty)
            #expect(box.draft.text.isEmpty)
        }

        /// While editing, or where the host cannot upload, a copied file
        /// pastes as the text view always pasted it.
        @Test func withoutStagingACopiedFilePastesAsText() {
            let box = Box()
            let view = field(box, staging: false)
            let board = pasteboard(copiedInFinder)
            defer { board.releaseGlobally() }

            _ = view.readSelection(from: board)

            #expect(box.files.isEmpty)
            #expect(!view.string.isEmpty)
        }

        @Test func textPastesAsText() {
            let box = Box()
            let view = field(box)
            let board = pasteboard { $0.setString("On my way", forType: .string) }
            defer { board.releaseGlobally() }

            #expect(view.readSelection(from: board))

            #expect(view.string == "On my way")
            #expect(box.draft.text == "On my way")
            #expect(box.files.isEmpty && box.images.isEmpty)
        }

        /// Cells copied from a spreadsheet carry a picture of themselves too;
        /// the person meant the text.
        @Test func textCopiedWithAPictureOfItselfStaysText() throws {
            let box = Box()
            let view = field(box)
            let png = try Self.png()
            let board = pasteboard { board in
                board.declareTypes([.png, .string], owner: nil)
                board.setData(png, forType: .png)
                board.setString("42", forType: .string)
            }
            defer { board.releaseGlobally() }

            _ = view.readSelection(from: board)

            #expect(view.string == "42")
            #expect(box.images.isEmpty)
        }

        @Test func aCopiedPictureIsStagedAsPNG() throws {
            let box = Box()
            let view = field(box)
            let png = try Self.png()
            let board = pasteboard { $0.setData(png, forType: .png) }
            defer { board.releaseGlobally() }

            #expect(view.readSelection(from: board))

            #expect(box.images == [ComposerPastedImage(data: png, type: .png)])
            #expect(view.string.isEmpty)
        }

        /// Most apps copy a picture as TIFF, which becomes PNG.
        @Test func aTIFFBecomesPNG() throws {
            let box = Box()
            let view = field(box)
            let tiff = try #require(NSBitmapImageRep(data: Self.png())?.tiffRepresentation)
            let board = pasteboard { $0.setData(tiff, forType: .tiff) }
            defer { board.releaseGlobally() }

            #expect(view.readSelection(from: board))

            let image = try #require(box.images.first)
            #expect(image.type == .png)
            #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }

        /// A host that cannot write a pasted picture gets no picture types.
        @Test func noPictureHandlerReadsNoPictures() {
            let readable = ComposerPaste.readableTypes(text: [.string, .png], images: false)
            #expect(readable.first == .fileURL)
            #expect(!readable.contains(.png) && !readable.contains(.tiff))
            #expect(readable.contains(.string))
        }

        @Test func filesComeFirstAndPicturesLast() throws {
            let readable = ComposerPaste.readableTypes(text: [.rtf, .string, .fileURL, .tiff], images: true)
            #expect(readable.first == .fileURL)
            let text = try #require(readable.firstIndex(of: .string))
            let picture = try #require(readable.firstIndex(of: .png))
            #expect(text < picture)
            #expect(readable.last == .tiff)
            #expect(readable.count(where: { $0 == .fileURL }) == 1)
        }

        /// A text paste is still one step Cmd-Z takes back.
        @Test func aTextPasteUndoes() {
            let box = Box()
            let view = field(box)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.contentView = view.enclosingScrollView
            let undo = view.undoManager ?? UndoManager()
            undo.groupsByEvent = false
            let board = pasteboard { $0.setString("Hello", forType: .string) }
            defer { board.releaseGlobally() }

            undo.beginUndoGrouping()
            _ = view.readSelection(from: board)
            undo.endUndoGrouping()
            #expect(view.string == "Hello")
            undo.undo()
            #expect(view.string.isEmpty)
            #expect(box.draft.text.isEmpty)
            withExtendedLifetime(window) {}
        }
    }
#endif

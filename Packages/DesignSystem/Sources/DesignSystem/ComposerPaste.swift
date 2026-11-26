#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers

    /// What a paste into the composer stages instead of typing: copied files,
    /// and a copied picture. Present only while the composer can stage one,
    /// which is when the host can upload and no edit is in progress (an edit
    /// never sends files); otherwise the field pastes text exactly as before,
    /// undo included, because every other type goes to `NSTextView`.
    struct ComposerPaste {
        let files: ([URL]) -> Void
        /// `nil` when the host cannot write a pasted picture to a file.
        let image: ((ComposerPastedImage) -> Void)?

        static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        static let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)

        /// In the order a picture is taken: compressed bytes as they came
        /// first, TIFF (which becomes PNG) last.
        static let imageTypes: [NSPasteboard.PasteboardType] = [.png, jpeg, heic, .tiff]

        /// The text view's own readable types, reordered for staging. AppKit
        /// pastes the first of these the pasteboard has.
        ///
        /// Files come first: a file copied in Finder also carries its name as
        /// text, and the person copied the file. Then every text type, so text
        /// copied along with a picture of itself (cells from a spreadsheet)
        /// still pastes as text. A picture comes last, when there is no text.
        static func readableTypes(
            text: [NSPasteboard.PasteboardType],
            images: Bool
        ) -> [NSPasteboard.PasteboardType] {
            let rest = text.filter { $0 != .fileURL && !imageTypes.contains($0) }
            return [.fileURL] + rest + (images ? imageTypes : [])
        }

        /// Stages what `type` holds and answers `true`, or answers `nil` for a
        /// type that is the text view's to paste.
        @MainActor
        func read(_ pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool? {
            if type == .fileURL {
                let urls = pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL] ?? []
                guard !urls.isEmpty else { return nil }
                files(urls)
                return true
            }
            guard let image, Self.imageTypes.contains(type),
                  let pasted = Self.image(from: pasteboard.data(forType: type), type: type)
            else { return nil }
            image(pasted)
            return true
        }

        /// The bytes as a file would hold them. TIFF, which is how most apps
        /// copy a picture, becomes PNG: few chat clients display a TIFF.
        static func image(from data: Data?, type: NSPasteboard.PasteboardType) -> ComposerPastedImage? {
            guard let data, !data.isEmpty else { return nil }
            switch type {
            case .png: return ComposerPastedImage(data: data, type: .png)
            case jpeg: return ComposerPastedImage(data: data, type: .jpeg)
            case heic: return ComposerPastedImage(data: data, type: .heic)
            case .tiff:
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                else { return nil }
                return ComposerPastedImage(data: png, type: .png)
            default: return nil
            }
        }
    }
#endif

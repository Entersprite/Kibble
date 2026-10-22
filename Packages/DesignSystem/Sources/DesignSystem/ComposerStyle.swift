#if os(macOS)
    import AppKit
    import ChatKit

    /// The field's type, and how it draws tokens and formatting: bold text
    /// bold, italic italic, underlined, struck through, and code in a
    /// monospaced face on a faint fill, as Notes and Messages draw them,
    /// never as markup. Tokens use the accent style `MessageTextAttributes`
    /// gives someone else's mention in a bubble.
    ///
    /// Everything drawn comes from the draft. The one attribute written for
    /// another reason is `styleKey`.
    @MainActor
    enum ComposerStyle {
        typealias Style = ComposerDraft.Style
        typealias Run = ComposerDraft.Run

        static var font: NSFont {
            .preferredFont(forTextStyle: .body)
        }

        static var base: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor.labelColor]
        }

        /// Each character's formatting, as `ComposerDraft.Style` bits, kept
        /// in the text storage itself. AppKit's undo and redo put back the
        /// attributes of the text they restore, a deletion's and a format
        /// change's alike, so formatting comes back with its text and the
        /// draft follows the view (`ComposerDraft.follow`), as it does for
        /// the text. A draft-only record would lose the styles of any text
        /// an undo brought back.
        static let emojiKey = NSAttributedString.Key("KibbleComposerEmoji")

        static let styleKey = NSAttributedString.Key("KibbleComposerStyles")

        /// The faint fill behind code. A system fill, so it follows the
        /// appearance and Increase Contrast.
        static var codeBackground: NSColor {
            .tertiarySystemFill
        }

        /// What a character with `styles` looks like, `styleKey` included.
        static func attributes(for styles: Set<Style>, token: Bool = false) -> [NSAttributedString.Key: Any] {
            var result = base
            if !styles.isEmpty {
                result[styleKey] = bits(styles)
            }
            if !styles.isEmpty || token {
                result[.font] = face(for: styles, token: token)
            }
            if token {
                result[.foregroundColor] = NSColor.controlAccentColor
            }
            if styles.contains(.underline) {
                result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if styles.contains(.strikethrough) {
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if styles.contains(.code) || styles.contains(.codeBlock) {
                result[.backgroundColor] = codeBackground
            }
            return result
        }

        /// The body size throughout: monospaced for code, bold for bold and
        /// semibold for a token, slanted for italic.
        private static func face(for styles: Set<Style>, token: Bool) -> NSFont {
            let size = font.pointSize
            let weight: NSFont.Weight = styles.contains(.bold) ? .bold : token ? .semibold : .regular
            var face: NSFont = styles.contains(.code) || styles.contains(.codeBlock)
                ? .monospacedSystemFont(ofSize: size, weight: weight)
                : weight == .regular ? font : .systemFont(ofSize: size, weight: weight)
            if styles.contains(.italic) {
                let descriptor = face.fontDescriptor
                    .withSymbolicTraits(face.fontDescriptor.symbolicTraits.union(.italic))
                face = NSFont(descriptor: descriptor, size: size) ?? face
            }
            return face
        }

        /// Draws the whole draft into `view`: its tokens and runs, and the
        /// typing attributes for the caret. Never during an input method's
        /// composition, which owns the marked text's look.
        static func apply(_ draft: ComposerDraft, to view: NSTextView) {
            guard let storage = view.textStorage, !view.hasMarkedText() else { return }
            let length = storage.length
            var edges = Set([0, length])
            for run in draft.runs {
                edges.formUnion([run.location, run.end])
            }
            for token in draft.tokens {
                edges.formUnion([token.location, token.end])
            }
            let stops = edges.filter { $0 >= 0 && $0 <= length }.sorted()
            storage.beginEditing()
            for (start, end) in zip(stops, stops.dropFirst()) where end > start {
                let styles = ComposerRuns.styles(at: start, in: draft.runs)
                let token = draft.tokens.contains { $0.location <= start && start < $0.end }
                storage.setAttributes(
                    attributes(for: styles, token: token),
                    range: NSRange(location: start, length: end - start)
                )
            }
            for span in draft.customEmoji where span.range(in: draft.text) != nil {
                if let data = try? JSONEncoder().encode(span.emoji) {
                    storage.addAttribute(
                        emojiKey,
                        value: data,
                        range: NSRange(location: span.start, length: span.length)
                    )
                }
            }
            storage.endEditing()
            let selection = view.selectedRange()
            setTyping(draft.insertionStyles(location: selection.location, length: selection.length), in: view)
        }

        /// The typing attributes for `styles`, so what is typed next, an
        /// input method's marked text included, looks as it will.
        static func setTyping(_ styles: Set<Style>, in view: NSTextView) {
            guard !view.hasMarkedText() else { return }
            let wanted = attributes(for: styles)
            guard (view.typingAttributes[styleKey] as? Int) != (wanted[styleKey] as? Int)
                || view.typingAttributes[.font] as? NSFont != wanted[.font] as? NSFont
                || view.typingAttributes[emojiKey] != nil
            else { return }
            view.typingAttributes = wanted
        }

        /// Writes the formatting `runs` give each character in `range` into
        /// `storage`'s `styleKey`, for a format change AppKit records for
        /// undo. The look follows from the draft once it has read them back.
        static func mark(_ runs: [Run], in range: NSRange, of storage: NSTextStorage) {
            var edges = Set([range.location, NSMaxRange(range)])
            for run in runs where run.location < NSMaxRange(range) && range.location < run.end {
                edges.formUnion([max(run.location, range.location), min(run.end, NSMaxRange(range))])
            }
            let stops = edges.sorted()
            for (start, end) in zip(stops, stops.dropFirst()) where end > start {
                let span = NSRange(location: start, length: end - start)
                let styles = ComposerRuns.styles(at: start, in: runs)
                if styles.isEmpty {
                    storage.removeAttribute(styleKey, range: span)
                } else {
                    storage.addAttribute(styleKey, value: bits(styles), range: span)
                }
            }
        }

        /// The formatting the storage holds, read back from `styleKey`.
        static func runs(in text: NSAttributedString) -> [Run] {
            var runs: [Run] = []
            text.enumerateAttribute(
                styleKey,
                in: NSRange(location: 0, length: text.length)
            ) { value, span, _ in
                guard let value = value as? Int else { return }
                for (index, style) in Style.allCases.enumerated() where value & (1 << index) != 0 {
                    runs.append(Run(style: style, location: span.location, length: span.length))
                }
            }
            return ComposerRuns.normalized(runs)
        }

        static func customEmoji(in text: NSAttributedString) -> [MessageCustomEmoji] {
            var result: [MessageCustomEmoji] = []
            text.enumerateAttribute(emojiKey, in: NSRange(
                location: 0,
                length: text.length
            )) { value, range, _ in
                guard let data = value as? Data, let emoji = try? JSONDecoder().decode(
                    CustomEmojiRef.self,
                    from: data
                ) else { return }
                let span = MessageCustomEmoji(emoji: emoji, start: range.location, length: range.length)
                if span.range(in: text.string) != nil {
                    result.append(span)
                }
            }
            return result
        }

        private static func bits(_ styles: Set<Style>) -> Int {
            Style.allCases.enumerated().reduce(0) { bits, entry in
                styles.contains(entry.element) ? bits | (1 << entry.offset) : bits
            }
        }

        /// Measured on a private TextKit stack, never the view's own, which
        /// keeps its container at the frame's width and so answers for the
        /// frame rather than the text: one line at least, `maxLines` at most.
        static func height(of text: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(
                width: max(1, width),
                height: CGFloat.greatestFiniteMagnitude
            ))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            var used = layout.usedRect(for: container)
            if !layout.extraLineFragmentRect.isEmpty {
                used = used.union(layout.extraLineFragmentRect)
            }
            let line = layout.defaultLineHeight(for: font)
            return min(max(used.height, line), line * CGFloat(maxLines)).rounded(.up)
        }
    }
#endif

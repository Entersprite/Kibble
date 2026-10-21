#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The format button sits between the field and the emoji button and must
    /// match them: a borderless pull-down drew a chevron beside its label,
    /// which made it wider than tall and shrank its glass circle off center.
    @MainActor
    struct ComposerFormattingButtonTests {
        @Test func theFormatButtonIsTheSameCircleAsTheButtonsBesideIt() {
            let format = NSHostingView(rootView: ComposerFormattingButton { _ in })
            let emoji =
                NSHostingView(rootView: RoundGlassButton(title: "Emoji", systemImage: "face.smiling") {})
            let side = ComposerLayout.lineHeight
            #expect(format.fittingSize == CGSize(width: side, height: side))
            #expect(format.fittingSize == emoji.fittingSize)
        }
    }
#endif

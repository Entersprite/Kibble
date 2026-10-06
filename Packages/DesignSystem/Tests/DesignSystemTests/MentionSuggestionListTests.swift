#if os(macOS)
    import AppKit
    import Testing
    @testable import DesignSystem

    /// CLAUDE.md: an SF Symbol name is an unchecked string.
    struct MentionSuggestionListTests {
        @Test func theAllSymbolExists() {
            #expect(
                NSImage(systemSymbolName: MentionSuggestionRow.allSymbol, accessibilityDescription: nil) !=
                    nil
            )
        }
    }
#endif

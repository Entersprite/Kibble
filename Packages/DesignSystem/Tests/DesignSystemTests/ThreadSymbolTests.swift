#if os(macOS)
    import AppKit
    import Testing
    @testable import DesignSystem

    /// An SF Symbol name is an unchecked string: a wrong one renders as empty
    /// space (`CLAUDE.md`). Every symbol the thread views use is checked.
    @MainActor
    struct ThreadSymbolTests {
        @Test(arguments: ThreadsPresentation.symbols)
        func theSymbolExists(_ name: String) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
    }
#endif

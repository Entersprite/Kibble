#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    /// CLAUDE.md: an SF Symbol name is an unchecked string.
    struct MentionSuggestionListTests {
        @Test func anOutsideRowSaysSoBeforeItsEmail() {
            let person = ChatKit.Member(
                id: ChatKit.Member.ID("o"), kind: .human, displayName: "O", email: "o@example.invalid"
            )
            let outside = MentionSuggestion(
                target: .user(person.id),
                name: "O",
                member: person,
                outsideConversation: true
            )
            let inside = MentionSuggestion(target: .user(person.id), name: "O", member: person)
            #expect(MentionSuggestionRow.detail(of: outside) == "Not in this space · o@example.invalid")
            #expect(MentionSuggestionRow.detail(of: inside) == "o@example.invalid")
        }

        @Test func theAllSymbolExists() {
            #expect(
                NSImage(systemSymbolName: MentionSuggestionRow.allSymbol, accessibilityDescription: nil) !=
                    nil
            )
        }
    }
#endif

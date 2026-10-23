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

        @Test func anOutsideRowInAGroupChatSaysSo() {
            let person = ChatKit.Member(
                id: ChatKit.Member.ID("o"), kind: .human, displayName: "O", email: "o@example.invalid"
            )
            let outside = MentionSuggestion(
                target: .user(person.id), name: "O", member: person, outsideConversation: true
            )
            #expect(MentionSuggestionRow.detail(of: outside, place: "group chat")
                == "Not in this group chat · o@example.invalid")
            #expect(MentionSuggestionRow.spoken(outside, place: "group chat")
                == "O, Not in this group chat · o@example.invalid")
        }

        /// A person shown by their email does not have it repeated beneath.
        @Test func anEmailShownAsTheNameIsNotRepeated() {
            let person = ChatKit.Member(id: ChatKit.Member.ID("n"), kind: .human, email: "n@example.invalid")
            let outside = MentionSuggestion(
                target: .user(person.id), name: "n@example.invalid", member: person, outsideConversation: true
            )
            #expect(MentionSuggestionRow.detail(of: outside) == "Not in this space")
        }

        /// What VoiceOver hears for the highlighted row, the keyboard being
        /// in the field: the row's two lines.
        @Test func theHighlightedRowIsSpokenAsItReads() {
            let person = ChatKit.Member(
                id: ChatKit.Member.ID("j"), kind: .human, displayName: "Jane Doe",
                email: "jane@example.invalid"
            )
            let noEmail = ChatKit.Member(id: ChatKit.Member.ID("n"), kind: .human, displayName: "Nadia")
            let jane = MentionSuggestion(target: .user(person.id), name: "Jane Doe", member: person)
            let everyone = MentionSuggestion(target: .all, name: "all", member: nil)
            let nadia = MentionSuggestion(target: .user(noEmail.id), name: "Nadia", member: noEmail)
            #expect(MentionSuggestionRow.spoken(jane) == "Jane Doe, jane@example.invalid")
            #expect(MentionSuggestionRow.spoken(everyone) == "@all, Notify everyone in this space")
            #expect(MentionSuggestionRow.spoken(nadia) == "Nadia")
        }

        @Test func theAllSymbolExists() {
            #expect(
                NSImage(systemSymbolName: MentionSuggestionRow.allSymbol, accessibilityDescription: nil) !=
                    nil
            )
        }
    }
#endif

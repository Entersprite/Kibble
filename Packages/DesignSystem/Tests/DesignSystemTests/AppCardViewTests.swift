#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// A card offers only what this window can do: its links, and its actions
    /// where the window can send them. Nothing takes the person to the
    /// provider's own client.
    @MainActor
    struct AppCardViewTests {
        private let content = AppCard(
            header: .init(title: RichText("GitHub · New commits")),
            sections: [.init(widgets: [.text(RichText("a1b2c3d - Prevent backlogs"))])]
        )

        private func height(_ card: AppCard, perform: Bool) -> CGFloat {
            NSHostingView(rootView: AppCardView(
                card: card, load: nil, perform: perform ? { _ in AppCardActionResult() } : nil
            )
            .frame(width: 400)).fittingSize.height
        }

        /// Actions the window cannot send leave no empty strip where their
        /// buttons would be.
        @Test func actionsWithoutAHandlerDrawNothing() {
            var withActions = content
            withActions.actions = [AppCardAction(id: "a", label: "Acknowledge")]
            #expect(height(withActions, perform: false) == height(content, perform: false))
            #expect(height(withActions, perform: true) > height(content, perform: true))
        }

        /// A card with nothing this window can draw or do is the note, not
        /// an empty box.
        @Test func aCardOfUnsendableActionsAloneIsTheNote() {
            let actionsOnly = AppCard(actions: [AppCardAction(id: "a", label: "Acknowledge")])
            let note = height(AppCard(), perform: false)
            #expect(height(actionsOnly, perform: false) == note)
            #expect(height(actionsOnly, perform: true) != note)
        }
    }
#endif

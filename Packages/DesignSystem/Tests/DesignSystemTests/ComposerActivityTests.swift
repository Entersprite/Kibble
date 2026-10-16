#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct ComposerActivityTests {
        @Test func programmaticRestorationIsSilentButActualInputAndBlurReportActivity() {
            var draft = ComposerDraft()
            var events: [Bool] = []
            let field = ComposerTextView(
                draft: Binding(get: { draft }, set: { draft = $0 }),
                anchorX: .constant(0),
                listOpen: false,
                focusRequest: 0,
                onKey: { _ in },
                onSubmit: {},
                onActivity: { events.append($0) }
            )
            let coordinator = field.makeCoordinator()
            let scroll = ComposerScrollView.make()
            scroll.textView.delegate = coordinator
            draft.edit("Restored")
            coordinator.show(draft, in: scroll.textView)
            #expect(events.isEmpty)
            scroll.textView.string = "Actual input"
            coordinator.textDidChange(Notification(
                name: NSText.didChangeNotification,
                object: scroll.textView
            ))
            #expect(events == [true])
            coordinator.textDidEndEditing(Notification(
                name: NSText.didEndEditingNotification,
                object: scroll.textView
            ))
            #expect(events == [true, false])
        }
    }
#endif

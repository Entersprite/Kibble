#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The sidebar's own footer, drawn where no account shell is: its gear is
    /// the system's round glass button, as tall as the account capsule.
    @MainActor
    struct SidebarFooterTests {
        /// The glass style adds its own padding to the label; at the regular
        /// control size the button must still be exactly the capsule's height,
        /// or the two controls stop lining up.
        @Test func theGearIsAsTallAsTheAccountCapsule() {
            let gear = NSHostingView(rootView: SidebarSettingsButton {})
            #expect(gear.fittingSize == CGSize(
                width: SidebarFooter.controlSize,
                height: SidebarFooter.controlSize
            ))
        }

        /// Without `signOut` there is no running session, so the row draws nothing.
        @Test func theFooterIsDrawnOnlyWhereThereIsASessionToSignOutOf() {
            let me = Member.ID("users/me")
            let state = ChatSceneState(
                directory: [me: Member(id: me, kind: .human, displayName: "Me")],
                me: me
            )
            let none = NSHostingView(rootView: SidebarFooter(state: state, actions: ChatSceneActions()))
            let shown = NSHostingView(rootView: SidebarFooter(
                state: state, actions: ChatSceneActions(signOut: {}, showSettings: {})
            ))
            #expect(none.fittingSize.height == 0)
            #expect(shown.fittingSize.height == SidebarFooter.controlSize + 20)
        }
    }
#endif

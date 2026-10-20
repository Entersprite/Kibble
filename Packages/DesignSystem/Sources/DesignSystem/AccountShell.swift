import ChatKit
import SwiftUI

/// The window's content with the account pill at the bottom of its sidebar.
/// Clicking the pill grows it into one Liquid Glass panel: your status above
/// the pill, a divider, and every account to its right.
///
/// The pill is drawn here, above the whole window, not inside the sidebar:
/// the panel grows past the sidebar over the conversation, which the sidebar's
/// hosting view would clip. `content` must place an `AccountFooterAnchor` in its
/// sidebar (`ConversationList` does under this shell, also while the selected
/// account is not running); the pill follows it.
public struct AccountShell<Content: View>: View {
    let state: AccountPanelState
    let actions: AccountPanelActions
    @Binding var isPanelOpen: Bool
    let content: Content
    @State private var geometry = AccountFooterGeometry()

    public init(
        state: AccountPanelState, actions: AccountPanelActions, isPanelOpen: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.actions = actions
        _isPanelOpen = isPanelOpen
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.accountFooter, geometry)
            .overlay {
                AccountFooterOverlay(state: state, actions: actions, geometry: geometry, isOpen: $isPanelOpen)
            }
            .onChange(of: state.selectedID) { isPanelOpen = false }
    }
}

@MainActor
enum AccountPanelLayout {
    static let controlSize = SidebarFooter.controlSize
    static let avatarSize = SidebarFooter.avatarSize
    static let avatarInset = SidebarFooter.avatarInset
    /// How far the panel reaches past the pill's leading and bottom edges.
    static let grow: CGFloat = 8
    /// The pill's radius plus `grow`, so the two stay concentric.
    static let panelRadius = controlSize / 2 + grow
    static let topInset: CGFloat = 14
    static let gap: CGFloat = 14
    static let sectionGap: CGFloat = 10
    static let tileWidth: CGFloat = 88
    static let tileAvatar: CGFloat = 54
    /// Header, tiles and Manage Accounts…, measured from the panel's top inset.
    static let accountsHeight: CGFloat = 170

    /// Header, three availability rows, a divider and Set a Status…; a set
    /// status adds its line and Clear Status.
    static func statusHeight(hasStatusLine: Bool) -> CGFloat {
        hasStatusLine ? 194 : 142
    }
}

/// Covers the window, drawing only the pill and, while open, the panel plus a
/// layer that closes it on a click anywhere else, as a menu does.
struct AccountFooterOverlay: View {
    let state: AccountPanelState
    let actions: AccountPanelActions
    let geometry: AccountFooterGeometry
    @Binding var isOpen: Bool
    @State private var ownFrame: CGRect = .zero
    @State private var editingStatus = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isOpen {
                Color.black.opacity(0.001)
                    .contentShape(.rect)
                    .onTapGesture { isOpen = false }
                    .accessibilityHidden(true)
                Button("Close Account Panel") { isOpen = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            if let row = rowRect {
                let footer = AccountFooter(
                    state: state, actions: actions, rowWidth: row.width,
                    // Up to the window's trailing edge, keeping the margin the
                    // panel has at its leading edge.
                    maxWidth: ownFrame.width - 2 * (row.minX - AccountPanelLayout.grow),
                    isOpen: $isOpen, editStatus: { editingStatus = true }
                )
                footer.offset(
                    x: row.minX - AccountPanelLayout.grow,
                    y: row.maxY + AccountPanelLayout.grow - footer.height
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowFrameReader { ownFrame = $0 })
        .ignoresSafeArea()
        .sheet(isPresented: $editingStatus) {
            SetStatusSheet(current: state.scene.flatMap(Self.status), reactions: actions.reactions) {
                actions.setStatus?($0)
            }
        }
    }

    /// The pill row in this overlay's own coordinates. Both frames are in
    /// window coordinates, whose origin is the bottom left.
    private var rowRect: CGRect? {
        let row = geometry.row
        guard row.width > 0, ownFrame.width > 0 else { return nil }
        return CGRect(
            x: row.minX - ownFrame.minX,
            y: ownFrame.maxY - row.maxY,
            width: row.width,
            height: row.height
        )
    }

    static func status(_ scene: ChatSceneState) -> MemberStatus? {
        Display.ownStatus(directory: scene.directory, me: scene.me, connection: scene.connection, now: .now)
    }
}

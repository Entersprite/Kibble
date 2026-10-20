import ChatKit
import SwiftUI

/// The pill row and, open, the panel grown out of it. Drawn in a canvas as
/// big as the open panel, anchored at the pill row's bottom-leading corner;
/// closed, only the pill and the gear take clicks.
///
/// How the glass is built, each part learned the hard way:
/// - The container holds glass only. It draws its glass above any plain
///   sibling, so the content sits above it, outside.
/// - Spacing 0, so the closed pill and gear stay two shapes; open, the gear's
///   circle lies inside the panel and merges into it.
/// - One surface whose frame animates, so the panel grows out of the pill,
///   and the sections are masked to that frame and fade in after it: a morph
///   between two separate shapes showed the content before the glass reached it.
struct AccountFooter: View {
    let state: AccountPanelState
    let actions: AccountPanelActions
    let rowWidth: CGFloat
    /// The widest the panel may grow before the account row scrolls.
    let maxWidth: CGFloat
    @Binding var isOpen: Bool
    let editStatus: () -> Void
    @State private var pillWidth: CGFloat = 160
    @State private var highlight: AccountPanelTarget?
    #if os(macOS)
        @State private var doNotDisturbMenu = AccountPanelMenuAnchor()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = AccountPanelLayout

    private var showsStatus: Bool {
        state.scene?.capabilities.canSetStatus == true && actions.setAvailability != nil
            && actions.setStatus != nil
    }

    private var statusHeight: CGFloat {
        Layout.statusHeight(hasStatusLine: statusLine != nil)
    }

    private var statusLine: String? {
        state.scene.flatMap { scene in
            StatusMenuModel(
                availability: scene.availability, status: AccountFooterOverlay.status(scene), now: .now
            ).statusLine
        }
    }

    var height: CGFloat {
        let left = showsStatus ? statusHeight + Layout.sectionGap + Layout.controlSize : 0
        return Layout.topInset + max(left, Layout.accountsHeight) + Layout.grow
    }

    private var tileCount: Int {
        state.accounts.count + state.pendingSignIns.count + (actions.add == nil ? 0 : 1)
    }

    /// Every tile while they fit; then the room left, and the row scrolls.
    private var tilesWidth: CGFloat {
        CGFloat(tileCount) * Layout.tileWidth
    }

    private var roomForTiles: CGFloat {
        maxWidth - (Layout.grow + rowWidth + 3 * Layout.gap + 1)
    }

    private var accountsWidth: CGFloat {
        max(Layout.tileWidth, min(tilesWidth, roomForTiles))
    }

    private var width: CGFloat {
        Layout.grow + rowWidth + 3 * Layout.gap + 1 + accountsWidth
    }

    private var surface: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: 0.42, bounce: 0.16)
    }

    private var reveal: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2).delay(0.12)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            glass
            if isOpen {
                // Clicks inside the panel stay in it.
                Color.clear
                    .frame(width: width, height: height)
                    .contentShape(.rect(cornerRadius: Layout.panelRadius))
                    .onTapGesture {}
            }
            sections
                .frame(width: width, height: height, alignment: .bottomLeading)
                .modifier(AccountPanelKeyboard(
                    isOpen: isOpen, navigation: navigation, highlight: $highlight, choose: commands.perform
                ))
                .opacity(isOpen ? 1 : 0)
                .animation(isOpen ? reveal : .easeIn(duration: 0.08), value: isOpen)
                .mask(alignment: .bottomLeading) { surfaceShape }
                .allowsHitTesting(isOpen)
                .accessibilityHidden(!isOpen)
            bottomRow
                .padding(.leading, Layout.grow)
                .padding(.bottom, Layout.grow)
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .animation(surface, value: isOpen)
    }

    private var glass: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .frame(width: isOpen ? width : pillWidth, height: isOpen ? height : Layout.controlSize)
                    .glassEffect(
                        isOpen ? .regular : .regular.interactive(),
                        in: .rect(cornerRadius: isOpen ? Layout.panelRadius : Layout.controlSize / 2)
                    )
                    .padding(.leading, isOpen ? 0 : Layout.grow)
                    .padding(.bottom, isOpen ? 0 : Layout.grow)
                if actions.showSettings != nil {
                    Color.clear
                        .frame(width: Layout.controlSize, height: Layout.controlSize)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .padding(.leading, Layout.grow + rowWidth - Layout.controlSize)
                        .padding(.bottom, Layout.grow)
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private var surfaceShape: some View {
        RoundedRectangle(cornerRadius: isOpen ? Layout.panelRadius : Layout.controlSize / 2)
            .frame(width: isOpen ? width : pillWidth, height: isOpen ? height : Layout.controlSize)
            .padding(.leading, isOpen ? 0 : Layout.grow)
            .padding(.bottom, isOpen ? 0 : Layout.grow)
    }

    private var navigation: AccountPanelNavigation {
        AccountPanelNavigation(
            state: state, actions: actions,
            status: showsStatus ? AccountStatusSection.rows(hasStatusLine: statusLine != nil) : []
        )
    }

    private var commands: AccountPanelCommands {
        AccountPanelCommands(
            actions: actions, close: { isOpen = false }, editStatus: editStatus,
            doNotDisturb: openDoNotDisturb
        )
    }

    /// Built when it opens, so each duration counts from then.
    private func openDoNotDisturb() {
        #if os(macOS)
            guard let scene = state.scene else { return }
            let model = StatusMenuModel(
                availability: scene.availability, status: AccountFooterOverlay.status(scene), now: .now
            )
            let commands = commands
            doNotDisturbMenu.open(model.doNotDisturbChoices.map { choice in
                (choice.title, {
                    if let until = choice.until(now: .now, calendar: .current) {
                        commands.set(.doNotDisturb(until: until))
                    }
                })
            })
        #endif
    }

    /// Status above the pill, the divider, and the account picker on the right.
    private var sections: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if showsStatus, let scene = state.scene {
                    statusSection(scene)
                        .frame(width: rowWidth, height: statusHeight, alignment: .topLeading)
                } else {
                    Text("Your status can be set while this account is connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(width: rowWidth, alignment: .leading)
                }
            }
            .padding(.leading, Layout.grow)
            .padding(.bottom, Layout.grow + Layout.controlSize + Layout.sectionGap)
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: height - 2 * Layout.topInset)
                .padding(.leading, Layout.grow + rowWidth + Layout.gap)
                .padding(.bottom, Layout.topInset)
            AccountPickerSection(
                state: state, actions: actions, width: accountsWidth, scrolls: tilesWidth > accountsWidth,
                commands: commands, highlight: $highlight
            )
            .frame(width: accountsWidth, height: height - Layout.topInset - Layout.grow, alignment: .top)
            .padding(.leading, Layout.grow + rowWidth + 2 * Layout.gap + 1)
            .padding(.bottom, Layout.grow)
        }
    }

    private func statusSection(_ scene: ChatSceneState) -> AccountStatusSection {
        #if os(macOS)
            AccountStatusSection(
                scene: scene, label: state.showsLabels ? state.selected?.label : nil, actions: actions,
                commands: commands, highlight: $highlight, doNotDisturbMenu: doNotDisturbMenu
            )
        #else
            AccountStatusSection(
                scene: scene, label: state.showsLabels ? state.selected?.label : nil, actions: actions,
                commands: commands, highlight: $highlight
            )
        #endif
    }

    /// Avatar, name and gear: in the same place open or closed. No glass of
    /// their own; theirs is drawn in the container underneath.
    private var bottomRow: some View {
        HStack(spacing: 10) {
            AccountPill(state: state, isOpen: isOpen) { isOpen.toggle() }
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
            Spacer(minLength: 8)
            if let scene = state.scene, let marks = Self.marks(scene) {
                marks
            }
            if let showSettings = actions.showSettings {
                Button {
                    isOpen = false
                    showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: Layout.controlSize, height: Layout.controlSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .frame(width: rowWidth, height: Layout.controlSize)
    }

    /// Your own status and calendar marks, beside the gear as before.
    private static func marks(_ scene: ChatSceneState) -> PersonMarks? {
        PersonMarks(
            status: Display.ownStatus(
                directory: scene.directory,
                me: scene.me,
                connection: scene.connection,
                now: .now
            ),
            calendar: Display.ownCalendar(
                directory: scene.directory, me: scene.me, connection: scene.connection, now: .now
            ),
            now: .now
        )
    }
}

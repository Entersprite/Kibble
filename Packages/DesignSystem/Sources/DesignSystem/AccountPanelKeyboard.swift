#if os(macOS)
    import AppKit
#endif
import ChatKit
import SwiftUI

/// The open panel's keyboard, as a menu's: one focus stop whose highlight the
/// arrows and Tab move, and Return or Space choose. The pointer moves the same
/// highlight, so there is never a second one, and there is no focus ring: in a
/// list or collection the keyboard's place is shown by a highlight.
struct AccountPanelKeyboard: ViewModifier {
    let isOpen: Bool
    let navigation: AccountPanelNavigation
    @Binding var highlight: AccountPanelTarget?
    /// `nil` when Return is pressed with nothing highlighted, which closes.
    let choose: (AccountPanelTarget?) -> Void
    @FocusState private var focused: Bool
    @State private var recent = AccountPanelNavigation.Recent()

    func body(content: Content) -> some View {
        content
            .focusable(isOpen)
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                highlight = navigation.move(from: highlight, direction: direction, recent: recent)
            }
            .onKeyPress(phases: .down) { press in
                switch press.key {
                case .tab, Self.backTab:
                    let backward = press.key == Self.backTab || press.modifiers.contains(.shift)
                    highlight = navigation.next(after: highlight, backward: backward)
                    return .handled
                case .return, .space:
                    choose(highlight)
                    return .handled
                default:
                    return .ignored
                }
            }
            .onChange(of: highlight) { _, target in recent.note(target) }
            .onChange(of: isOpen, initial: true) { _, open in
                highlight = nil
                recent = .init()
                focused = open
            }
    }

    /// Shift-Tab arrives as its own character, not as Tab with Shift.
    private static let backTab = KeyEquivalent("\u{19}")
}

/// What choosing each target does, for a click and for Return alike.
@MainActor
struct AccountPanelCommands {
    let actions: AccountPanelActions
    let close: () -> Void
    let editStatus: () -> Void
    /// Offers Do not disturb's durations beside its row; choosing one sets it.
    let doNotDisturb: () -> Void

    func perform(_ target: AccountPanelTarget?) {
        switch target {
        case .status(.automatic): set(.automatic)
        case .status(.away): set(.away)
        case .status(.doNotDisturb): doNotDisturb()
        case .status(.setStatus):
            close()
            editStatus()
        case .status(.clearStatus):
            close()
            actions.setStatus?(nil)
        case let .account(id):
            close()
            actions.select(id)
        case let .pending(id):
            close()
            actions.resumeSignIn?(id)
        case .add:
            close()
            actions.add?()
        case .manage:
            close()
            actions.manage?()
        case nil:
            close()
        }
    }

    func set(_ availability: Availability) {
        close()
        actions.setAvailability?(availability)
    }
}

extension View {
    /// The pointer moves the panel's one highlight, as the arrows do.
    func accountPanelHover(
        _ target: AccountPanelTarget, highlight: Binding<AccountPanelTarget?>
    ) -> some View {
        onHover { inside in
            if inside {
                highlight.wrappedValue = target
            } else if highlight.wrappedValue == target {
                highlight.wrappedValue = nil
            }
        }
    }
}

/// The highlight behind a row or a tile, the same for the pointer and the keys.
struct AccountPanelHighlight: View {
    let isOn: Bool
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(isOn ? 0.08 : 0))
    }
}

#if os(macOS)
    /// Opens a native menu beside the row it sits behind, as a submenu opens.
    /// A SwiftUI `Menu` opens only for the pointer; this opens for Return too.
    /// The panel sits low in the window, and AppKit scrolls a popped-up menu
    /// that runs past the screen's bottom, so it rises as far as it must, as a
    /// submenu does there.
    @MainActor
    final class AccountPanelMenuAnchor {
        fileprivate weak var view: NSView?

        func open(_ items: [(title: String, run: () -> Void)]) {
            guard let view, !items.isEmpty else { return }
            let menu = NSMenu()
            for entry in items {
                let trampoline = ReactionMenuTrampoline(entry.run)
                let item = NSMenuItem(
                    title: entry.title, action: #selector(ReactionMenuTrampoline.choose(_:)),
                    keyEquivalent: ""
                )
                item.target = trampoline
                // `target` is weak: the item keeps the trampoline alive itself.
                item.representedObject = trampoline
                menu.addItem(item)
            }
            let rise = Self.rise(menu, beside: view)
            let top = view.isFlipped ? view.bounds.minY - rise : view.bounds.maxY + rise
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: top), in: view)
        }

        /// How far above the row's top the menu must start to fit above the
        /// bottom of the screen's usable area.
        private static func rise(_ menu: NSMenu, beside view: NSView) -> CGFloat {
            guard let window = view.window, let screen = window.screen else { return 0 }
            let row = window.convertToScreen(view.convert(view.bounds, to: nil))
            let below = row.maxY - screen.visibleFrame.minY
            return max(0, min(menu.size.height - below, screen.visibleFrame.maxY - row.maxY))
        }
    }

    struct AccountPanelMenuAnchorView: NSViewRepresentable {
        let anchor: AccountPanelMenuAnchor

        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }

        func updateNSView(_ view: NSView, context _: Context) {
            anchor.view = view
        }
    }
#endif

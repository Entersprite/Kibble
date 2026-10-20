import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The open panel in a real window, driven by key events: one focus stop
/// whose highlight the arrows and Tab move, and Return chooses.
@MainActor
struct AccountPanelHostedTests {
    @Test func rightAndReturnChooseTheNextAccountWithoutChangingGeometry() throws {
        let panel = try Hosted()
        defer { panel.close() }
        let width = panel.host.frame.width
        try panel.press(.right, .return)
        #expect(panel.probe.chosen == ["select second"])
        #expect(!panel.probe.isOpen)
        #expect(panel.host.frame.width == width)
    }

    @Test func leftOfTheFirstAccountReachesTheStatusRows() throws {
        let panel = try Hosted()
        defer { panel.close() }
        try panel.press(.left, .down, .down, .return)
        #expect(panel.probe.chosen == ["availability away"])
        #expect(!panel.probe.isOpen)
    }

    @Test func tabAndShiftTabStartAtEitherEndOfTheReadingOrder() throws {
        let forward = try Hosted()
        defer { forward.close() }
        try forward.press(.tab, .return)
        #expect(forward.probe.chosen == ["availability automatic"])
        let backward = try Hosted()
        defer { backward.close() }
        try backward.press(.backTab, .return)
        #expect(backward.probe.chosen == ["manage"])
    }

    @Test func returnWithNothingHighlightedClosesAndChoosesNothing() throws {
        let panel = try Hosted()
        defer { panel.close() }
        #expect(panel.probe.isOpen)
        try panel.press(.return)
        #expect(panel.probe.chosen.isEmpty)
        #expect(!panel.probe.isOpen)
    }
}

@MainActor
private final class Probe {
    var chosen: [String] = []
    var isOpen = false
}

private struct PanelHost: View {
    let probe: Probe
    @State private var isOpen = false

    var body: some View {
        AccountFooter(
            state: state, actions: actions, rowWidth: 220, maxWidth: 760, isOpen: $isOpen, editStatus: {}
        )
        .onAppear { isOpen = true }
        .onChange(of: isOpen, initial: true) { _, open in probe.isOpen = open }
    }

    private var state: AccountPanelState {
        let rows = ["first", "second"].map { id in
            AccountPanelAccount(
                id: id, label: id, name: nil, email: nil, managedBy: nil, unread: 0, problem: nil,
                isEnabled: true, me: .init(id), directory: [:], imageLoader: nil
            )
        }
        let scene = ChatSceneState(
            me: Member.ID("first"), availability: .automatic, capabilities: Capabilities(canSetStatus: true)
        )
        return AccountPanelState(accounts: rows, selectedID: "first", scene: scene)
    }

    private var actions: AccountPanelActions {
        let probe = probe
        return AccountPanelActions(
            select: { probe.chosen.append("select \($0)") },
            manage: { probe.chosen.append("manage") },
            setAvailability: { availability in
                switch availability {
                case .automatic: probe.chosen.append("availability automatic")
                case .away: probe.chosen.append("availability away")
                default: probe.chosen.append("availability other")
                }
            },
            setStatus: { _ in probe.chosen.append("status") }
        )
    }
}

private struct KeyEvent {
    let code: UInt16
    let text: String
    var flags: NSEvent.ModifierFlags = []
}

@MainActor
private struct Hosted {
    enum Key {
        case left, right, down, `return`, tab, backTab

        var event: KeyEvent {
            let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
            return switch self {
            case .left: KeyEvent(code: 123, text: "\u{F702}", flags: arrow)
            case .right: KeyEvent(code: 124, text: "\u{F703}", flags: arrow)
            case .down: KeyEvent(code: 125, text: "\u{F701}", flags: arrow)
            case .return: KeyEvent(code: 36, text: "\r")
            case .tab: KeyEvent(code: 48, text: "\t")
            case .backTab: KeyEvent(code: 48, text: "\u{19}", flags: .shift)
            }
        }
    }

    let probe = Probe()
    let window: NSWindow
    let host: NSHostingView<PanelHost>

    init() throws {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        host = NSHostingView(rootView: PanelHost(probe: probe))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        renderTurn()
        host.layoutSubtreeIfNeeded()
        try #require(probe.isOpen)
    }

    func press(_ keys: Key...) throws {
        for key in keys {
            let key = key.event
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key.text,
                charactersIgnoringModifiers: key.text, isARepeat: false, keyCode: key.code
            ))
            window.sendEvent(event)
            renderTurn()
        }
    }

    func close() {
        window.orderOut(nil)
    }

    private func renderTurn() {
        for _ in 0 ..< 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

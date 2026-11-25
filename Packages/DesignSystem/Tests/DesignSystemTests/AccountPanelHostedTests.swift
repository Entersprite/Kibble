import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The open panel in a real window, driven by key events: one focus stop
/// whose highlight the arrows and Tab move, and Return chooses.
@MainActor
@Suite(.enabled(if: visibleUITestsEnabled))
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

    @Test func doNotDisturbExpiresWhileThePanelStaysOpen() async throws {
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let end = Date().addingTimeInterval(3)
        let panel = try Hosted(availability: .doNotDisturb(until: end), throughShell: true)
        defer { panel.close() }
        try await panel.renderUntil(end) {
            panel.accessibilityLabels.contains { $0.hasPrefix("Do not disturb until ") }
        }
        let initialLabels = panel.accessibilityLabels
        try #require(initialLabels.contains { $0.hasPrefix("Do not disturb until ") }, "\(initialLabels)")

        try await panel.renderUntil(end.addingTimeInterval(2)) {
            panel.accessibilityLabels.contains("Do not disturb")
        }

        #expect(panel.probe.isOpen)
        let expiredLabels = panel.accessibilityLabels
        #expect(!expiredLabels.contains { $0.hasPrefix("Do not disturb until ") })
        #expect(expiredLabels.contains("Do not disturb"))
    }
}

@MainActor
private final class Probe {
    var chosen: [String] = []
    var isOpen = false
}

private struct PanelHost: View {
    let probe: Probe
    let availability: Availability
    let throughShell: Bool
    @State private var isOpen = false

    var body: some View {
        Group {
            if throughShell {
                AccountShell(state: state, actions: actions, isPanelOpen: $isOpen) {
                    PanelAnchor()
                        .frame(width: 800, height: 300, alignment: .bottomLeading)
                }
            } else {
                AccountFooter(
                    state: state, actions: actions, rowWidth: 220, maxWidth: 760,
                    isOpen: $isOpen, now: .now, editStatus: {}
                )
            }
        }
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
            me: Member.ID("first"), availability: availability, capabilities: Capabilities(canSetStatus: true)
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

private struct PanelAnchor: View {
    @Environment(\.accountFooter) private var geometry

    var body: some View {
        if let geometry {
            AccountFooterAnchor(geometry: geometry)
                .frame(width: 240)
        }
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

    init(availability: Availability = .automatic, throughShell: Bool = false) throws {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        host = NSHostingView(rootView: PanelHost(
            probe: probe,
            availability: availability,
            throughShell: throughShell
        ))
        window.contentView = host
        placeAwayFromPointer()
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

    var accessibilityLabels: [String] {
        labels(in: host)
    }

    func renderUntil(_ deadline: Date, _ condition: () -> Bool) async throws {
        while Date() < deadline, !condition() {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func labels(in node: NSObject) -> [String] {
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        let childSelector = NSSelectorFromString("accessibilityChildren")
        let label = node.responds(to: labelSelector)
            ? node.perform(labelSelector)?.takeUnretainedValue() as? String : nil
        let children = node.responds(to: childSelector)
            ? node.perform(childSelector)?.takeUnretainedValue() as? [NSObject] : nil
        return (label.map { [$0] } ?? []) + (children ?? []).flatMap(labels(in:))
    }

    /// Hover shares the keyboard highlight. The real desktop pointer must
    /// not select a row while this harness is testing an empty highlight.
    private func placeAwayFromPointer() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let corners = [
            NSPoint(x: frame.minX, y: frame.minY),
            NSPoint(x: frame.maxX - size.width, y: frame.minY),
            NSPoint(x: frame.minX, y: frame.maxY - size.height),
            NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        ]
        if let origin = corners.first(where: {
            !NSRect(origin: $0, size: size).insetBy(dx: -20, dy: -20).contains(NSEvent.mouseLocation)
        }) {
            window.setFrameOrigin(origin)
        }
    }

    private func renderTurn() {
        for _ in 0 ..< 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

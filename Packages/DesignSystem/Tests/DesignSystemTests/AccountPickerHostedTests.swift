import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct AccountPickerHostedTests {
    @Test func arrowAndReturnActivateTheFocusedAccountWithoutChangingGeometry() throws {
        _ = NSApplication.shared
        var selected: [String] = []
        var closed = false
        let rows = ["first", "second"].map { id in
            AccountPanelAccount(
                id: id,
                label: id,
                name: nil,
                email: nil,
                managedBy: nil,
                unread: 0,
                problem: nil,
                isEnabled: true,
                me: .init(id),
                directory: [:],
                imageLoader: nil
            )
        }
        let state = AccountPanelState(accounts: rows, selectedID: "first", scene: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let root = AccountPickerSection(
            state: state,
            actions: .init(select: { selected.append($0) }),
            width: 176,
            scrolls: false,
            close: { closed = true },
            isOpen: true
        )
        let host = NSHostingView(rootView: root)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        renderTurn()
        host.layoutSubtreeIfNeeded()
        let width = host.frame.width
        try key(window, code: 124, text: String(#require(UnicodeScalar(0xF703))))
        renderTurn()
        try key(window, code: 36, text: "\r")
        renderTurn()
        #expect(selected == ["second"])
        #expect(closed)
        #expect(host.frame.width == width)
    }

    private func renderTurn() {
        for _ in 0 ..< 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func key(_ window: NSWindow, code: UInt16, text: String) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: code
        ))
        window.sendEvent(event)
    }
}

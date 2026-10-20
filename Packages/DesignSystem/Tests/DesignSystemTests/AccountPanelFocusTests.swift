import AppKit
import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct AccountPanelFocusTests {
    @Test func dismissingRestoresTheOriginalFieldButNeverAnotherAccountsResponder() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let text = NSTextView(frame: NSRect(x: 10, y: 20, width: 200, height: 100))
        let bridge = AccountPanelFocusBridge.FocusView()
        root.addSubview(text); root.addSubview(bridge); window.contentView = root
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(text))
        bridge.update(open: true, account: "first")
        #expect(window.makeFirstResponder(window))
        bridge.update(open: false, account: "first")
        #expect(window.firstResponder === text)
        bridge.update(open: true, account: "first")
        #expect(window.makeFirstResponder(window))
        bridge.update(open: false, account: "second")
        #expect(window.firstResponder !== text)
    }

    @Test func detachedPreviousViewsAreNeverRefocused() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let text = NSTextView(frame: .zero)
        let bridge = AccountPanelFocusBridge.FocusView()
        window.contentView?.addSubview(text); window.contentView?.addSubview(bridge)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        bridge.update(open: true, account: "first")
        text.removeFromSuperview()
        bridge.update(open: false, account: "first")
        #expect(window.firstResponder !== text)
    }
}

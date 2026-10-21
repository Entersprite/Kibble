import AppKit
import Testing
@testable import MacHost

/// Where Save As and its failure alert attach: the key window, else the main
/// one, while it is on screen. A panel with no such window runs on its own.
@MainActor
struct SystemDownloadSheetTests {
    private func window(visible: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if visible {
            window.orderFront(nil)
        }
        return window
    }

    @Test func theKeyWindowTakesTheSheetBeforeTheMainOne() {
        let key = window(visible: true)
        let main = window(visible: true)
        defer {
            key.close()
            main.close()
        }
        #expect(SystemDownloadPlatform.sheetWindow(key: key, main: main) === key)
    }

    @Test func aWindowOffScreenTakesNoSheet() {
        let hidden = window(visible: false)
        let main = window(visible: true)
        defer { main.close() }
        #expect(SystemDownloadPlatform.sheetWindow(key: hidden, main: main) === main)
        #expect(SystemDownloadPlatform.sheetWindow(key: hidden, main: nil) == nil)
    }

    @Test func withNoWindowThereIsNoSheet() {
        #expect(SystemDownloadPlatform.sheetWindow(key: nil, main: nil) == nil)
    }
}

#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    /// A pane's native list in a window, for what a person does with the
    /// keyboard: select a row through the table, then press Return.
    @MainActor
    struct HostedList<Content: View> {
        let window: NSWindow
        let host: NSHostingView<Content>
        let table: NSTableView

        init(_ content: Content) throws {
            _ = NSApplication.shared
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 420), styleMask: [.titled],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: content)
            window.contentView = host
            Self.turn()
            host.layoutSubtreeIfNeeded()
            table = try #require(Self.tables(in: host).first)
        }

        /// The rows a person can select: the items, not a section's header.
        var selectableRows: [Int] {
            (0 ..< table.numberOfRows).filter {
                table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == false
            }
        }

        func select(row: Int) throws {
            window.makeFirstResponder(table)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            Self.turn()
            #expect(table.selectedRow == row)
        }

        func pressReturn() throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            window.sendEvent(event)
            Self.turn()
        }

        func close() {
            window.close()
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }

        private static func turn() {
            for _ in 0 ..< 5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
    }
#endif

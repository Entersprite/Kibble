import AppKit

/// The Help menu's documents: the disclaimer, Kibble's license and the
/// third-party notices, each in a window of its own. Read-only, selectable and
/// resizable, and brought forward again rather than opened twice.
///
/// AppKit rather than a SwiftUI `Window` scene: each is a text view with nothing
/// to observe, and a scene would join window restoration at launch and need
/// `openWindow` from inside the menu commands.
@MainActor
public enum HelpWindows {
    public enum Document: Sendable {
        case disclaimer
        case license
        case acknowledgments

        var title: String {
            switch self {
            case .disclaimer: "Disclaimer"
            case .license: "License"
            case .acknowledgments: "Acknowledgments"
            }
        }

        var size: NSSize {
            switch self {
            case .disclaimer: NSSize(width: 460, height: 200)
            case .license: NSSize(width: 540, height: 420)
            case .acknowledgments: NSSize(width: 620, height: 560)
            }
        }
    }

    private static var windows: [Document: NSWindow] = [:]

    public static func show(_ document: Document, bundle: Bundle = .main) {
        let window = windows[document] ?? makeWindow(document, bundle: bundle)
        windows[document] = window
        window.makeKeyAndOrderFront(nil)
    }

    public static func openSource() {
        NSWorkspace.shared.open(LegalText.sourceURL)
    }

    static func content(_ document: Document, bundle: Bundle) -> NSAttributedString {
        switch document {
        case .disclaimer:
            LegalText.disclaimerDocument()
        case .license:
            LegalText.licenseDocument(LegalText.text(named: LegalText.licenseFile, in: bundle))
        case .acknowledgments:
            LegalText.acknowledgmentsDocument(LegalText.text(named: LegalText.noticesFile, in: bundle))
        }
    }

    private static func makeWindow(_ document: Document, bundle: Bundle) -> NSWindow {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.textStorage?.setAttributedString(content(document, bundle: bundle))
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: document.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = document.title
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

import AppKit

/// About Kibble: the standard panel, with three short lines about the MIT
/// License as its credits (`LegalText.aboutCredits()`). The disclaimer and the
/// license texts are in the Help menu (`HelpWindows`).
public enum AboutPanel {
    @MainActor
    public static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: LegalText.aboutCredits()])
    }
}

import AppKit
import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// `AttachmentChip`'s decisions, pure and tested without rendering anything -
/// `CLAUDE.md`: a green gate says nothing about geometry, so the render step
/// is separate and lives in the task report, not here.
///
/// Swift Testing also declares `Attachment` (its own attachment-to-report
/// type), so every attachment literal below is `ChatKit.Attachment`.
struct AttachmentChipTests {
    @Test(arguments: [
        (AttachmentDownloadState.idle, "paperclip", AttachmentChip.Primary.download),
        (.downloading(AttachmentProgress(bytesReceived: 1, totalBytes: 4)), "paperclip", .none),
        (.done, "doc", .open),
        (.failed("Sign in again to download files"), "exclamationmark.triangle.fill", .download)
    ])
    func presentation(_ state: AttachmentDownloadState, _ symbol: String, _ primary: AttachmentChip.Primary) {
        let shown = AttachmentChip.Presentation(state: state)
        #expect(shown.symbol == symbol)
        #expect(shown.primary == primary)
    }

    @Test("the primary button's accessibility label names the action and the file", arguments: [
        (AttachmentDownloadState.idle, "Download a.pdf"),
        (.downloading(AttachmentProgress(bytesReceived: 1, totalBytes: 4)), "Downloading a.pdf"),
        (.done, "Open a.pdf"),
        (.failed("Sign in again to download files"), "Download a.pdf")
    ])
    func accessibilityLabels(_ state: AttachmentDownloadState, _ expected: String) {
        #expect(AttachmentChip.Presentation(state: state).accessibilityLabel(for: "a.pdf") == expected)
    }

    @Test("Save As is offered in every state but downloading", arguments: [
        (AttachmentDownloadState.idle, true),
        (.downloading(AttachmentProgress(bytesReceived: 1, totalBytes: 4)), false),
        (.downloading(AttachmentProgress(bytesReceived: 1, totalBytes: nil)), false),
        (.done, true),
        (.failed("x"), true)
    ])
    func saveAsIsOffered(_ state: AttachmentDownloadState, _ offered: Bool) {
        #expect(AttachmentChip.Presentation(state: state).offersSaveAs == offered)
    }

    /// A body longer than its stated size - a server that understated it -
    /// fills the bar and says 100 percent, never more.
    @Test("the bar and the percentage stop at the total", arguments: [
        (1, 4, 1.0, "25 percent"),
        (4, 4, 4.0, "100 percent"),
        (9, 4, 4.0, "100 percent")
    ])
    func barStopsAtTheTotal(_ received: Int, _ total: Int, _ value: Double, _ percent: String) {
        let shown = AttachmentChip.Presentation(
            state: .downloading(AttachmentProgress(bytesReceived: received, totalBytes: total))
        )
        #expect(shown.bar == AttachmentChip.Bar(value: value, total: Double(total)))
        #expect(shown.percentLabel == percent)
    }

    @Test("an unknown or zero total, and every other state, has no bar and no percentage", arguments: [
        AttachmentDownloadState.downloading(AttachmentProgress(bytesReceived: 9, totalBytes: nil)),
        .downloading(AttachmentProgress(bytesReceived: 9, totalBytes: 0)),
        .idle,
        .done,
        .failed("x")
    ])
    func noBar(_ state: AttachmentDownloadState) {
        let shown = AttachmentChip.Presentation(state: state)
        #expect(shown.bar == nil)
        #expect(shown.percentLabel == nil)
    }

    @Test("the failure's message is the help text, and nothing else is")
    func failureHelp() {
        #expect(AttachmentChip.Presentation(state: .failed("x")).help == "x")
        #expect(AttachmentChip.Presentation(state: .idle).help == nil)
    }

    /// `sizeLabel` is a static member of `AttachmentChip`, which conforms to
    /// `View` - a `@preconcurrency` protocol, so the main-actor isolation that
    /// conformance infers is enforced at runtime rather than at compile time.
    /// Calling it from a plain nonisolated test traps
    /// (`_swift_task_checkIsolatedSwift`); `@MainActor` here is what the
    /// CLAUDE.md rule about a `@MainActor`-only helper is really about.
    @MainActor
    @Test("a known size is shown, an unknown one is not")
    func sizeLabel() {
        let sized = ChatKit.Attachment(id: "a", name: "a", contentType: "application/pdf", byteSize: 2048)
        #expect(AttachmentChip.sizeLabel(sized) == "2 KB")
        let unsized = ChatKit.Attachment(id: "b", name: "b", contentType: "application/pdf")
        #expect(AttachmentChip.sizeLabel(unsized) == nil)
    }

    @Test("every symbol the chip can draw exists")
    func symbolsExist() {
        let names = [
            "paperclip",
            "doc",
            "exclamationmark.triangle.fill",
            "xmark.circle.fill",
            "arrow.down.circle"
        ]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}

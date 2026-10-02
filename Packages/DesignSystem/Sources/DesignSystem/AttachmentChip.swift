import ChatKit
import SwiftUI

/// A non-image upload: its name and size, and - when the host can download
/// files - a click that downloads it, progress with a cancel button while it
/// does, a click that opens it once it is done, and Show in Finder / Save As
/// in the context menu.
struct AttachmentChip: View {
    let attachment: Attachment
    var state: AttachmentDownloadState = .idle
    var actions: AttachmentFileActions?

    enum Primary: Equatable { case download, open, none }

    /// What the chip shows and does for a state, apart from the view.
    struct Presentation: Equatable {
        let symbol: String
        let primary: Primary
        let help: String?

        init(state: AttachmentDownloadState) {
            switch state {
            case .idle: (symbol, primary, help) = ("paperclip", .download, nil)
            case .downloading: (symbol, primary, help) = ("paperclip", .none, nil)
            case .done: (symbol, primary, help) = ("doc", .open, nil)
            case let .failed(message): (symbol, primary, help) = (
                    "exclamationmark.triangle.fill",
                    .download,
                    message
                )
            }
        }

        /// The primary button's accessible name - the action, not the icon,
        /// since VoiceOver otherwise reads only "<name>, <size>, button" and
        /// never says whether a click downloads or opens the file. A failed
        /// state's `primary` is already `.download`, so it reads the same as
        /// idle; the failure message stays the hint/help, not the label.
        func accessibilityLabel(for name: String) -> String {
            switch primary {
            case .download: "Download \(name)"
            case .open: "Open \(name)"
            case .none: "Downloading \(name)"
            }
        }
    }

    static func sizeLabel(_ attachment: Attachment) -> String? {
        attachment.byteSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// The chip's `accessibilityValue` while a known-size download is under
    /// way - `nil` (so nothing is attached) for every other state, and for an
    /// unknown total, since a percentage cannot be said of a spinner.
    private var downloadPercentLabel: String? {
        guard case let .downloading(progress) = state, let total = progress.totalBytes, total > 0 else {
            return nil
        }
        let percent = Int((Double(progress.bytesReceived) / Double(total) * 100).rounded())
        return "\(percent) percent"
    }

    var body: some View {
        if let actions {
            interactive(actions)
        } else {
            label(symbol: "paperclip")
        }
    }

    private func label(symbol: String) -> some View {
        HStack(spacing: 6) {
            Label(AttachmentLayout.label(for: attachment), systemImage: symbol)
                .lineLimit(1)
                .truncationMode(.middle)
            if let size = Self.sizeLabel(attachment) {
                Text(size).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func interactive(_ actions: AttachmentFileActions) -> some View {
        let shown = Presentation(state: state)
        let name = AttachmentLayout.label(for: attachment)
        HStack(spacing: 6) {
            Button {
                switch shown.primary {
                case .download: actions.download(attachment)
                case .open: actions.open(attachment)
                case .none: break
                }
            } label: {
                label(symbol: shown.symbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shown.accessibilityLabel(for: name))
            .conditionalHelp(shown.help)
            if case let .downloading(progress) = state {
                if let total = progress.totalBytes, total > 0 {
                    ProgressView(value: Double(progress.bytesReceived), total: Double(total))
                        .frame(width: 60)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button { actions.cancel(attachment) } label: {
                    Label("Cancel download", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
        }
        .conditionalAccessibilityValue(downloadPercentLabel)
        .contextMenu {
            if state == .done {
                Button("Open") { actions.open(attachment) }
                Button("Show in Finder") { actions.reveal(attachment) }
            } else if case .downloading = state {
                Button("Cancel Download") { actions.cancel(attachment) }
            } else {
                Button("Download") { actions.download(attachment) }
            }
            Button("Save As…") { actions.saveAs(attachment) }
        }
    }
}

private extension View {
    /// `.help(_:)`, but attaches nothing for `nil` rather than an empty
    /// tooltip - an idle or done chip has no failure message to show.
    @ViewBuilder func conditionalHelp(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }

    /// `.accessibilityValue(_:)`, but attaches nothing for `nil` rather than
    /// an empty value - only a known-size download in progress has a
    /// percentage to report.
    @ViewBuilder func conditionalAccessibilityValue(_ text: String?) -> some View {
        if let text {
            accessibilityValue(text)
        } else {
            self
        }
    }
}

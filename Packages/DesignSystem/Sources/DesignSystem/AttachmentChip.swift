import ChatKit
import SwiftUI

/// A non-image upload: its name and size, and - when the host can download
/// files - a click that downloads it, progress with a cancel button while it
/// does, a click that opens it once it is done, and Show in Finder / Save As
/// in the context menu. A finished file can also be dragged out, shared and
/// shown in Quick Look, when the host says where it is (`finishedFile`).
struct AttachmentChip: View {
    let attachment: Attachment
    var state: AttachmentDownloadState = .idle
    var actions: AttachmentFileActions?
    /// The row's menu, which the chip's replaces: its reactions and items
    /// stay, acting on the row's message (links spec §7.3's rule for cards).
    var menu: MessageMenuContext?
    /// Opens the message's Quick Look pages at this file.
    var quickLook: ((Attachment) -> Void)?

    enum Primary: Equatable { case download, open, none }

    /// A known-size transfer's progress bar.
    struct Bar: Equatable {
        let value: Double
        let total: Double
    }

    /// What the chip shows and does for a state, apart from the view.
    struct Presentation: Equatable {
        let symbol: String
        let primary: Primary
        let help: String?
        /// Whether the context menu offers Save As - not while a transfer
        /// runs, when the coordinator would ignore it.
        let offersSaveAs: Bool
        /// The bar for a transfer whose size is known; `nil` for a spinner
        /// and for every other state.
        let bar: Bar?

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
            if case let .downloading(progress) = state {
                offersSaveAs = false
                // A body can outrun the size it was announced with; the bar
                // stops full rather than past its end.
                if let total = progress.totalBytes, total > 0 {
                    bar = Bar(value: Double(min(progress.bytesReceived, total)), total: Double(total))
                } else {
                    bar = nil
                }
            } else {
                offersSaveAs = true
                bar = nil
            }
        }

        /// The chip's `accessibilityValue` while a known-size download is
        /// under way - `nil` (so nothing is attached) otherwise, since a
        /// percentage cannot be said of a spinner.
        var percentLabel: String? {
            bar.map { "\(Int(($0.value / $0.total * 100).rounded())) percent" }
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

    var body: some View {
        if let actions {
            interactive(actions)
        } else {
            // No menu of its own: the row's applies.
            label(symbol: "paperclip")
        }
    }

    /// The finished file, for a drag or a share, asked only when one begins.
    private func transfer(_ actions: AttachmentFileActions) -> AttachmentTransfer? {
        guard state == .done, let finishedFile = actions.finishedFile else { return nil }
        let attachment = attachment
        return AttachmentTransfer(attachment: attachment) {
            guard let file = finishedFile(attachment) else { throw CocoaError(.fileNoSuchFile) }
            return file
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
        let transfer = transfer(actions)
        HStack(spacing: 6) {
            primary(actions, shown: shown, transfer: transfer)
                .accessibilityLabel(shown.accessibilityLabel(for: name))
                .conditionalHelp(shown.help)
            if case .downloading = state {
                if let bar = shown.bar {
                    ProgressView(value: bar.value, total: bar.total)
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
        .conditionalAccessibilityValue(shown.percentLabel)
        .contextMenu {
            MessageMenuContent(nestedIn: menu) {
                fileItems(actions, shown: shown, transfer: transfer)
            }
        }
    }

    /// The click that downloads or opens. Only a finished file with a known
    /// place can be dragged out; the chip holds no state of its own, so the
    /// two shapes cost nothing when a download finishes.
    @ViewBuilder private func primary(
        _ actions: AttachmentFileActions, shown: Presentation, transfer: AttachmentTransfer?
    ) -> some View {
        let button = Button {
            switch shown.primary {
            case .download: actions.download(attachment)
            case .open: actions.open(attachment)
            case .none: break
            }
        } label: {
            label(symbol: shown.symbol)
        }
        .buttonStyle(.plain)
        if let transfer {
            button.draggable(transfer)
        } else {
            button
        }
    }

    @ViewBuilder private func fileItems(
        _ actions: AttachmentFileActions, shown: Presentation, transfer: AttachmentTransfer?
    ) -> some View {
        if state == .done {
            Button("Open", systemImage: MessageMenuSymbols.open) { actions.open(attachment) }
            if let quickLook, transfer != nil {
                Button("Quick Look", systemImage: MessageMenuSymbols.quickLook) { quickLook(attachment) }
            }
            Button("Show in Finder", systemImage: MessageMenuSymbols.showInFinder) {
                actions.reveal(attachment)
            }
            if let transfer {
                ShareLink(item: transfer, preview: SharePreview(transfer.name))
            }
        } else if case .downloading = state {
            Button("Cancel Download", systemImage: MessageMenuSymbols.cancelDownload) {
                actions.cancel(attachment)
            }
        } else {
            Button("Download", systemImage: MessageMenuSymbols.download) { actions.download(attachment) }
        }
        if shown.offersSaveAs {
            Button("Save As…", systemImage: MessageMenuSymbols.saveAs) { actions.saveAs(attachment) }
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

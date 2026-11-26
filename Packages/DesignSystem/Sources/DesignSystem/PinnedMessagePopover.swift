import ChatKit
import SwiftUI

/// A pinned message in full, in the popover its preview opens. The system's
/// popover closes on Escape and on a click outside and keeps the reader's
/// place; going to the message is the explicit Go to Message, or a click on
/// the message itself.
struct PinnedMessagePopover: View {
    let message: Message
    /// The window's state, with the pins' members known and no pins, so the
    /// copy carries no pin glyph of its own.
    let state: ChatSceneState
    let actions: ChatSceneActions
    /// `nil` where the host cannot open a message.
    let navigate: (() -> Void)?
    /// `nil` where the pins cannot be changed.
    let unpin: (() -> Void)?
    var isBusy = false
    @ScaledMetric(relativeTo: .body) private var maximumHeight = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContentSizedPinPreview(maximumWidth: 600, maximumHeight: maximumHeight) {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView { content }
                }
            }
            HStack {
                if let unpin {
                    Button("Unpin", systemImage: MessageMenuSymbols.unpin, action: unpin)
                        .disabled(isBusy)
                        .accessibilityIdentifier("unpin-pinned-message")
                }
                Spacer(minLength: 12)
                if let navigate {
                    Button("Go to Message", action: navigate)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("go-to-pinned-message")
                }
            }
        }
        .padding(14)
        .frame(minWidth: 260, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expanded-pin-preview")
    }

    @ViewBuilder private var content: some View {
        if let navigate {
            Button(action: navigate) {
                bubble.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to pinned message: \(PinnedPreviewSpeech.preview(of: message))")
            .accessibilityIdentifier("pinned-message-content")
        } else {
            bubble
        }
    }

    private var bubble: some View {
        MessageBubble(
            message: message, state: MessageRowState(message: message, scene: state),
            loadAttachment: actions.loadAttachment, openAttachment: actions.openAttachment,
            loadRemoteImage: actions.loadRemoteImage, attachmentFiles: actions.attachmentFiles,
            openReference: navigate
        )
        .padding(.horizontal, 4)
    }
}

/// Uses the message's ideal size, then re-proposes bounded space so long content scrolls.
struct ContentSizedPinPreview: Layout {
    var maximumWidth: CGFloat
    var maximumHeight: CGFloat

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(maximumWidth, content.sizeThatFits(.unspecified).width)
        let natural = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: min(natural.height, maximumHeight))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

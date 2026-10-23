import ChatKit
import SwiftUI

/// Shared pins remain within reach while the transcript scrolls underneath.
/// Expansion changes only this presentation; navigation is an explicit action.
struct PinnedMessageBubbles: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    @State private var expanded: Message.ID?
    @State private var showingMore = false
    @ScaledMetric(relativeTo: .callout) private var pinWidth = 88
    @ScaledMetric(relativeTo: .callout) private var minimumPreviewWidth = 180
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var messages: [Message] {
        state.pins.messages.enumerated().filter { !$0.element.isDeleted }.sorted {
            if $0.element.createdAt == $1.element.createdAt {
                return $0.offset < $1.offset
            }
            return $0.element.createdAt > $1.element.createdAt
        }.map(\.element)
    }

    var body: some View {
        if state.capabilities.canReadMessagePins {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    if expanded != nil || showingMore {
                        Color.clear.contentShape(Rectangle()).onTapGesture { collapse() }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if !messages.isEmpty {
                            pinCollection(
                                width: max(0, geometry.size.width - 24),
                                height: max(100, min(380, geometry.size.height - 24))
                            )
                        }
                        if let error = state.pinsError {
                            HStack {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                Button("Retry") { actions.refreshPins?() }
                            }
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onExitCommand { collapse() }
            .onChange(of: messages.map(\.id)) { _, ids in
                if let expanded, !ids.contains(expanded) {
                    self.expanded = nil
                }
            }
        }
    }

    private func pinCollection(width: CGFloat, height: CGFloat) -> some View {
        let allFit = CGFloat(messages.count) * (minimumPreviewWidth + 8) - 8 <= width
        let count = allFit ? messages.count : max(1, Int((width - pinWidth) / (minimumPreviewWidth + 8)))
        let visible = Array(messages.prefix(count))
        let remaining = Array(messages.dropFirst(count))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(visible, id: \.id) { message in compact(message) }
                if !remaining.isEmpty {
                    disclosure(hiddenCount: remaining.count)
                }
            }
            if showingMore, !remaining.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(remaining, id: \.id) { message in compact(message) }
                    }
                    .padding(2)
                }
                .frame(height: min(CGFloat(remaining.count) * 38, height - 42))
                .padding(.trailing, pinWidth + 8)
            }
            if let message = messages.first(where: { $0.id == expanded }) {
                ContentSizedPinPreview(
                    maximumWidth: min(600, width),
                    maximumHeight: height
                ) {
                    expandedMessage(message)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: width, alignment: .leading)
        .onChange(of: remaining.isEmpty) { _, empty in
            if empty {
                showingMore = false
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: expanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: showingMore)
    }

    private func disclosure(hiddenCount: Int) -> some View {
        Button {
            expanded = nil
            showingMore.toggle()
        } label: {
            HStack(spacing: 6) {
                Label("\(hiddenCount)", systemImage: "pin.fill")
                Image(systemName: showingMore ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PinGlassButtonStyle())
        .frame(width: pinWidth)
        .accessibilityLabel("Pinned messages, \(hiddenCount) hidden")
        .accessibilityIdentifier("pins-menu")
        .help("Show remaining pinned messages")
    }

    private func compact(_ message: Message) -> some View {
        Button {
            expanded = expanded == message.id ? nil : message.id
            showingMore = false
        } label: {
            HStack(spacing: 7) {
                Text(preview(message)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PinGlassButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Pinned message: \(preview(message))")
        .accessibilityHint("Expand to read the full message")
        .accessibilityIdentifier("pin-\(message.id.rawValue)")
    }

    func expandedMessage(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Pinned Message", systemImage: "pin.fill").font(.callout.weight(.semibold))
                Spacer()
                Button(action: collapse) {
                    Label("Collapse Message", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .accessibilityIdentifier("collapse-pin")
            }
            ViewThatFits(in: .vertical) {
                expandedContent(message).fixedSize(horizontal: false, vertical: true)
                ScrollView { expandedContent(message) }
            }
            HStack {
                if actions.openMessageReference != nil {
                    Button("Go to Message", systemImage: "arrow.up.forward") { navigate(to: message) }
                        .accessibilityIdentifier("go-to-pinned-message")
                }
                Spacer()
                if state.pins.canModify, let setPinned = actions.setMessagePinned {
                    Button("Unpin", systemImage: "pin.slash") { setPinned(false, message) }
                        .disabled(state.isLoadingPins)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .glassEffect(.regular.tint(.yellow.opacity(0.18)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expanded-pin-preview")
    }

    @ViewBuilder private func expandedContent(_ message: Message) -> some View {
        if actions.openMessageReference != nil {
            Button { navigate(to: message) } label: {
                previewBubble(message)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to pinned message: \(preview(message))")
            .accessibilityIdentifier("pinned-message-content")
        } else {
            previewBubble(message)
        }
    }

    private func previewBubble(_ message: Message) -> some View {
        MessageBubble(
            message: message, state: MessageRowState(message: message, scene: previewState),
            loadAttachment: actions.loadAttachment, openAttachment: actions.openAttachment,
            loadRemoteImage: actions.loadRemoteImage, attachmentFiles: actions.attachmentFiles,
            openReference: actions.openMessageReference.map { _ in { navigate(to: message) } }
        )
        .padding(.horizontal, 4)
    }

    private var previewState: ChatSceneState {
        var value = state
        for member in state.pins.members where value.directory[member.id] == nil {
            value.directory[member.id] = member
        }
        return value
    }

    private func preview(_ message: Message) -> String {
        if !message.text.isEmpty {
            return message.text.replacingOccurrences(of: "\n", with: " ")
        }
        if let name = message.attachments.first?.name {
            return name
        }
        return message.cards.first?.header?.title.plainText ?? "Pinned message"
    }

    private func navigate(to message: Message) {
        collapse()
        actions.openMessageReference?(MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        ))
    }

    private func collapse() {
        expanded = nil
        showingMore = false
    }
}

private struct PinGlassButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .callout) private var lineHeight = 18

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .frame(height: lineHeight)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .glassEffect(.regular.tint(.yellow.opacity(0.28)).interactive(), in: .capsule)
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

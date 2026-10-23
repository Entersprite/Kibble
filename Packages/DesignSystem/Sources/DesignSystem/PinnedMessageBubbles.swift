import ChatKit
import SwiftUI

/// Shared pins stay within reach while the transcript scrolls underneath.
///
/// One row of previews sits in a bar at the transcript's top, so the scroll
/// edge softens behind it and a jump to a message lands below it rather than
/// under it. The previews that do not fit are disclosed below the row, over
/// the transcript. A preview opens its message in a popover; navigation is
/// an explicit action there. Conversation › Show Pinned Messages puts the
/// keyboard on the row: the arrows move one highlight, Return chooses and
/// Escape leaves, as in a menu.
struct PinnedMessageBubbles: ViewModifier {
    let state: ChatSceneState
    let actions: ChatSceneActions
    @State private var expanded: Message.ID?
    @State private var showingMore = false
    /// How many previews the row shows: reported by the arrangement that fit.
    @State private var visibleCount = 0
    @State private var highlight: PinRowTarget?
    /// The row takes the keyboard only when asked, so a click on a preview
    /// never takes it from the composer.
    @State private var keyboard = false
    @State private var keyboardRequest = 0
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .callout) private var controlWidth = 88
    @ScaledMetric(relativeTo: .callout) private var minimumPreviewWidth = 180
    /// A disclosed row: the capsule's line and padding, and the list's spacing.
    @ScaledMetric(relativeTo: .callout) private var listRowHeight = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Newest first, as the provider's order breaks ties; deleted ones never show.
    private var messages: [Message] {
        state.pins.messages.enumerated().filter { !$0.element.isDeleted }.sorted {
            if $0.element.createdAt == $1.element.createdAt {
                return $0.offset < $1.offset
            }
            return $0.element.createdAt > $1.element.createdAt
        }.map(\.element)
    }

    private var isShown: Bool {
        state.capabilities.canReadMessagePins
    }

    func body(content: Content) -> some View {
        let pins = isShown ? messages : []
        let navigation = navigation(pins)
        content
            .overlay(alignment: .top) { overflow(pins) }
            .safeAreaBar(edge: .top, spacing: 0) { bar(pins, navigation: navigation) }
            .focusedSceneValue(\.pinnedMessages, PinnedMessagesCommand(
                scope: AccountScoped(account: state.accountID, value: state.selected),
                isAvailable: !pins.isEmpty
            ) { keyboardRequest += 1 })
            .onChange(of: keyboardRequest) {
                if keyboard {
                    focused = true
                    highlight = navigation.first
                } else {
                    keyboard = true
                }
            }
            .onChange(of: keyboard) { _, on in
                focused = on
                highlight = on ? navigation.first : nil
            }
            .onChange(of: focused) { _, on in
                // A popover takes the window's keys while it is open.
                if !on, expanded == nil {
                    keyboard = false
                }
            }
            .onChange(of: AccountScoped(account: state.accountID, value: state.selected)) {
                expanded = nil
                showingMore = false
                keyboard = false
            }
            .onChange(of: pins.map(\.id)) { _, ids in
                if let expanded, !ids.contains(expanded) {
                    self.expanded = nil
                }
                if ids.count <= visibleCount {
                    showingMore = false
                }
            }
    }

    // MARK: The row

    @ViewBuilder
    private func bar(_ pins: [Message], navigation: PinRowNavigation) -> some View {
        if isShown, !pins.isEmpty || state.pinsError != nil {
            GlassEffectContainer(spacing: 8) {
                // The most previews that fit beside the controls, never a
                // second line: each preview asks for its minimum width.
                ViewThatFits(in: .horizontal) {
                    ForEach(Self.arrangements(of: pins.count), id: \.self) { row(pins, visible: $0) }
                }
            }
            .onPreferenceChange(PinRowVisibleCount.self) { visibleCount = $0 }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .focusable(keyboard)
            .focused($focused)
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned Messages")
            .onMoveCommand { direction in
                switch direction {
                case .left, .up: highlight = navigation.move(from: highlight, forward: false)
                case .right, .down: highlight = navigation.move(from: highlight, forward: true)
                @unknown default: break
                }
            }
            .onKeyPress(phases: .down) { press in
                guard press.key == .return || press.key == .space else { return .ignored }
                if let highlight {
                    choose(highlight)
                }
                return .handled
            }
            .onExitCommand {
                if showingMore {
                    showingMore = false
                } else {
                    focused = false
                }
            }
        }
    }

    /// The preview counts to try, most first: every pin down to one, at most
    /// twelve wide; with no pins, the row of controls alone.
    static func arrangements(of count: Int) -> [Int] {
        count == 0 ? [0] : Array((1 ... min(count, 12)).reversed())
    }

    private func row(_ pins: [Message], visible count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(pins.prefix(count), id: \.id) { message in
                preview(message, inList: false)
                    .frame(
                        minWidth: minimumPreviewWidth,
                        idealWidth: minimumPreviewWidth,
                        maxWidth: .infinity
                    )
            }
            if pins.count > count {
                disclosure(hiddenCount: pins.count - count)
            }
            if let error = state.pinsError {
                retry(error)
            }
        }
        .preference(key: PinRowVisibleCount.self, value: count)
    }

    private func disclosure(hiddenCount: Int) -> some View {
        Button {
            choose(.more)
        } label: {
            HStack(spacing: 6) {
                Label {
                    Text("\(hiddenCount)")
                } icon: {
                    if state.isLoadingPins {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: PinStyle.symbol)
                    }
                }
                Image(systemName: showingMore ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PinGlassButtonStyle(highlighted: highlight == .more))
        .frame(width: controlWidth)
        .onHover { hover(.more, inside: $0) }
        .accessibilityLabel("Pinned messages, \(hiddenCount) hidden")
        .accessibilityValue(showingMore ? "Shown" : "")
        .accessibilityIdentifier("pins-menu")
        .help(showingMore ? "Hide remaining pinned messages" : "Show remaining pinned messages")
    }

    /// A failed refresh, in the row rather than beside it; the cached pins
    /// stay, and a failure is never shown as an empty board.
    private func retry(_ error: String) -> some View {
        Button {
            choose(.retry)
        } label: {
            Label("Retry", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(PinGlassButtonStyle(highlighted: highlight == .retry))
        .fixedSize()
        .disabled(actions.refreshPins == nil || state.isLoadingPins)
        .onHover { hover(.retry, inside: $0) }
        .help(error)
        .accessibilityLabel("Retry Pinned Messages")
        .accessibilityValue(error)
        .accessibilityIdentifier("pins-retry")
    }

    private func preview(_ message: Message, inList: Bool) -> some View {
        let target = PinRowTarget.message(message.id)
        return Button {
            choose(target, inList: inList)
        } label: {
            Text(PinnedPreviewSpeech.preview(of: message))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PinGlassButtonStyle(highlighted: highlight == target, inPanel: inList))
        .onHover { hover(target, inside: $0) }
        .popover(isPresented: presented(message.id), arrowEdge: .bottom) { popover(message) }
        .accessibilityLabel(PinnedPreviewSpeech.label(for: message, directory: directory, me: state.me))
        .accessibilityHint("Shows the full message")
        .accessibilityIdentifier("pin-\(message.id.rawValue)")
    }

    // MARK: The disclosed previews

    @ViewBuilder
    private func overflow(_ pins: [Message]) -> some View {
        let hidden = Array(pins.dropFirst(visibleCount))
        ZStack(alignment: .top) {
            // A click outside the disclosed list closes it, as a menu's does.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { showingMore = false }
                .allowsHitTesting(showingMore)
            // One glass panel that grows with its rows, as a menu does: separate
            // capsules left the transcript readable between them, and it read
            // through as clutter (owner, session366).
            if showingMore, !hidden.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(hidden, id: \.id) { preview($0, inList: true) }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(hidden.count) * listRowHeight + 12, 300))
                .scrollBounceBehavior(.basedOnSize)
                .glassEffect(PinStyle.panelGlass, in: .rect(cornerRadius: 18))
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: showingMore)
    }

    // MARK: Choosing

    private func navigation(_ pins: [Message]) -> PinRowNavigation {
        let count = min(visibleCount, pins.count)
        var row = pins.prefix(count).map { PinRowTarget.message($0.id) }
        if pins.count > count {
            row.append(.more)
        }
        if state.pinsError != nil {
            row.append(.retry)
        }
        let list = showingMore ? pins.dropFirst(count).map { PinRowTarget.message($0.id) } : []
        return PinRowNavigation(row: row, list: list)
    }

    /// What a click and Return do alike. A preview in the row closes the
    /// disclosed list; one in the list keeps it, so its popover keeps its anchor.
    private func choose(_ target: PinRowTarget, inList: Bool? = nil) {
        switch target {
        case let .message(id):
            if inList == false || (inList == nil && !isDisclosed(id)) {
                showingMore = false
            }
            expanded = expanded == id ? nil : id
        case .more:
            expanded = nil
            showingMore.toggle()
        case .retry:
            actions.refreshPins?()
        }
    }

    private func isDisclosed(_ id: Message.ID) -> Bool {
        showingMore && messages.dropFirst(visibleCount).contains { $0.id == id }
    }

    /// The pointer moves the same highlight the arrows do, so there is never a second one.
    private func hover(_ target: PinRowTarget, inside: Bool) {
        if inside {
            highlight = target
        } else if highlight == target, !keyboard {
            highlight = nil
        }
    }

    private func presented(_ id: Message.ID) -> Binding<Bool> {
        Binding {
            expanded == id
        } set: { shown in
            if !shown, expanded == id {
                expanded = nil
            }
        }
    }

    private func popover(_ message: Message) -> some View {
        PinnedMessagePopover(
            message: message,
            state: previewState,
            actions: actions,
            navigate: actions.openMessageReference.map { _ in { navigate(to: message) } },
            unpin: state.pins.canModify ? actions.setMessagePinned.map { setPinned in
                {
                    expanded = nil
                    setPinned(false, message)
                }
            } : nil,
            isBusy: state.isLoadingPins
        )
    }

    /// The window's directory with the pins' members added: a pin can come
    /// from someone no longer in it.
    private var directory: [Member.ID: Member] {
        state.directory.merging(state.pins.members.map { ($0.id, $0) }) { known, _ in known }
    }

    /// The window's state with the pins' members known, for names in the
    /// popover, and no pins, so the copy draws no glyph or outline.
    private var previewState: ChatSceneState {
        var value = state
        value.directory = directory
        value.pins.messages = []
        return value
    }

    private func navigate(to message: Message) {
        expanded = nil
        showingMore = false
        actions.openMessageReference?(MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        ))
    }
}

/// How many previews the arrangement `ViewThatFits` chose shows.
private struct PinRowVisibleCount: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

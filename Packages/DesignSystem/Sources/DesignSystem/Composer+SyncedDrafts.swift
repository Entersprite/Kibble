import ChatKit
import SwiftUI

public struct ComposerDraftReplacement: Equatable, Sendable {
    public let id: UUID
    public let expected: ComposedMessage?
    public let body: ComposedMessage?

    public init(id: UUID, expected: ComposedMessage?, body: ComposedMessage?) {
        self.id = id
        self.expected = expected
        self.body = body
    }
}

public struct ComposerDraftSyncStatus: Equatable, Sendable {
    public var replacement: ComposerDraftReplacement?
    public var conflict = false
    public var savedDraftWasCleared = false
    public var unsupportedContent = false
    public var failed = false

    public init() {}
}

public struct ComposerDraftSync {
    let connected: Bool
    let status: ComposerDraftSyncStatus
    let opened: () -> Void
    let resolved: (UUID, ComposedMessage?, Bool) -> Void
    let useSaved: () -> Void
    let keepLocal: (() -> Void)?
    let submitted: (ComposedMessage?) -> Void
    let send: ((ComposedMessage, ComposedMessage) -> Void)?
    let addAndSend: ((ComposedMessage, ComposedMessage, [Member.ID]) -> Void)?
    let isCurrentOffer: (UUID) -> Bool

    public init(
        connected: Bool, status: ComposerDraftSyncStatus, opened: @escaping () -> Void,
        resolved: @escaping (UUID, ComposedMessage?, Bool) -> Void,
        useSaved: @escaping () -> Void, keepLocal: (() -> Void)?,
        submitted: @escaping (ComposedMessage?) -> Void,
        send: ((ComposedMessage, ComposedMessage) -> Void)? = nil,
        addAndSend: ((ComposedMessage, ComposedMessage, [Member.ID]) -> Void)? = nil,
        isCurrentOffer: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.connected = connected
        self.status = status
        self.opened = opened
        self.resolved = resolved
        self.useSaved = useSaved
        self.keepLocal = keepLocal
        self.submitted = submitted
        self.send = send
        self.addAndSend = addAndSend
        self.isCurrentOffer = isCurrentOffer
    }
}

extension ComposerDraft {
    public var syncedComposition: ComposedMessage? {
        let body = scheduledComposition
        return body.text.isEmpty && body.content?.quote == nil ? nil : body
    }

    mutating func applySyncedDraft(_ offer: ComposerDraftReplacement, formatting: Bool) -> Bool {
        guard editing == nil, syncedComposition == offer.expected else { return false }
        clear()
        if let body = offer.body {
            if body.text.isEmpty {
                setQuote(body.content?.quote)
            } else {
                _ = adopt(nil, formatting: formatting)
                _ = adopt(body, formatting: formatting)
            }
        }
        return true
    }
}

extension Composer {
    var canApplySyncedDraft: Bool {
        attachments.isEmpty && draft.editing == nil && checking == nil && pendingInvite == nil
    }

    func applySyncedDraftOffer() {
        guard let sync = draftSync, let offer = sync.status.replacement,
              canApplySyncedDraft, sync.isCurrentOffer(offer.id) else { return }
        let applied = draft.applySyncedDraft(offer, formatting: allowsFormatting)
        sync.resolved(offer.id, draft.syncedComposition, applied)
    }

    func clearForSubmission() {
        draftSync?.submitted(draft.syncedComposition)
        draft.clear()
    }

    func sendWithDraftSync(_ message: ComposedMessage) -> Bool {
        guard let composition = draft.syncedComposition,
              let send = draftSync?.send else { return false }
        send(message, composition)
        draft.clear()
        return true
    }

    var syncedDraftLifecycle: some ViewModifier {
        ComposerDraftSyncLifecycle(
            sync: draftSync,
            canApply: canApplySyncedDraft,
            apply: applySyncedDraftOffer
        )
    }

    @ViewBuilder var draftSyncNotice: some View {
        if let sync = draftSync, sync.status.conflict || sync.status.failed {
            VStack(alignment: .leading, spacing: 4) {
                Text(draftSyncNoticeText(sync.status))
                    .font(.caption)
                    .foregroundStyle(draftSyncNoticeColor)
                if sync.connected, !sync.status.unsupportedContent {
                    HStack {
                        if sync.status.conflict {
                            Button(
                                sync.status.savedDraftWasCleared ? "Clear Composer" : "Use Saved Draft",
                                action: sync.useSaved
                            )
                            if let keepLocal = sync.keepLocal {
                                Button("Keep Mine", action: keepLocal)
                            }
                        } else {
                            Button("Try Again", action: sync.opened)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!canApplySyncedDraft)
                }
            }
        }
    }

    private var draftSyncNoticeColor: Color {
        #if os(macOS)
            Color(nsColor: .secondaryLabelColor)
        #else
            Color(uiColor: .secondaryLabel)
        #endif
    }

    private func draftSyncNoticeText(_ status: ComposerDraftSyncStatus) -> String {
        if status
            .unsupportedContent {
            return "The saved draft contains content this composer can’t restore."
        }
        if status.conflict {
            return status.savedDraftWasCleared ? "The saved draft was cleared on another device." :
                "The saved draft changed on another device."
        }
        return "This draft couldn’t be synced."
    }
}

private struct ComposerDraftSyncLifecycle: ViewModifier {
    let sync: ComposerDraftSync?
    let canApply: Bool
    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: sync?.connected) {
                if sync?.connected == true {
                    sync?.opened()
                }
            }
            .onChange(of: sync?.status.replacement, initial: true) { _, _ in apply() }
            .onChange(of: canApply) { _, enabled in
                if enabled {
                    apply()
                }
            }
    }
}

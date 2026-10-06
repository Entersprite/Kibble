import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// The launch machine, as a window sees it.
///
/// Separate from the state machine because they are two jobs, and because
/// `swiftlint --strict` enforces `type_body_length: 300` - the combined type
/// was close enough to the limit that the split is not merely tidiness.
public extension AppEnvironment {
    /// For the menu-bar agent, which has no room for a sidebar.
    var totalUnread: Int {
        guard case let .running(model) = phase else { return 0 }
        return model.conversations.reduce(0) { $0 + $1.unreadCount }
    }

    var sceneState: ChatSceneState {
        guard case let .running(model) = phase else {
            // `.failed` and `.report` are not the same kind of non-running:
            // one is a real problem and the other is a clean diagnostic run
            // that merely finished, and the two must not render under the
            // same warning triangle - see `StatusStrip` in `ChatWindow.swift`.
            // `lastError` and `notice` are how that distinction survives past
            // this point; collapsing them back into one string is exactly the
            // bug that put a triangle over a passing keychain check.
            switch phase {
            case let .failed(message):
                return ChatSceneState(lastError: .unknown(message))
            case let .report(message):
                return ChatSceneState(notice: message)
            case .loading, .needsSignIn, .running:
                return ChatSceneState()
            }
        }
        let rules = model.conversations.map { ($0.id, settings.resolved(for: $0)) }
        return ChatSceneState(
            conversations: model.conversations,
            directory: model.directory,
            me: model.me,
            selected: model.selected,
            messages: model.messages,
            typing: model.typing,
            connection: model.connectionState,
            lastError: model.lastError,
            capabilities: model.capabilities,
            failedDraft: model.failedDraft,
            unreadHidden: Set(rules.filter { !$0.1.showsUnread }.map(\.0)),
            dimmed: Set(rules.filter { $0.1.delivery == .off }.map(\.0)),
            muted: Set(model.conversations.map(\.id).filter(settings.isMuted)),
            receiptsWithheld: Set(rules.filter { !$0.1.readReceipts }.map(\.0)),
            showingMentions: model.showingMentions,
            mentions: mentionItems(of: model),
            mentionsStatus: MentionsStatus(
                running: model.mentionBackfill.running,
                failedConversations: model.mentionBackfill.failedConversations
            ),
            unreadMentionCount: model.unreadMentionCount,
            scrollTarget: model.scrollTarget,
            downloads: downloads?.states ?? [:],
            stagedAttachments: Self.composerAttachments(model.stagedAttachments),
            mentionCandidates: model.mentionCandidates,
            directoryResults: model.directoryResults
        )
    }

    /// The pure mapping beside the pane (`MentionItem.init`), fed from the
    /// session model. Rules do not hide a mention (spec §3).
    private func mentionItems(of model: ChatSessionModel) -> [MentionItem] {
        model.mentions.map { found in
            MentionItem(
                message: found.message, conversation: found.conversation, isUnread: found.isUnread,
                directory: model.directory, me: model.me
            )
        }
    }

    /// `reconnect` is left at its default `nil` - a deliberate choice, not a
    /// gap, and the reasoning has to live here because nothing else in the
    /// signature says so.
    ///
    /// `ChatBackend.connect()` is the only existing member that looks
    /// relevant, and the task that wired the rest of this taxonomy
    /// (`docs/journal/`) was explicit: wire it only if calling it on a
    /// live-but-reconnecting session is *obviously* safe, and never invent a
    /// new `ChatBackend` member to make a button work. Tracing both ends of
    /// that call settles it:
    ///
    /// - **A bare `connect()` is a safe no-op, which is worse than useless.**
    ///   `LocalBridgeBackend.connect()` opens with `guard !isConnected else {
    ///   return }`. `isConnected` flips back to `false` in exactly two places:
    ///   `channelStopped(_:)` (`LocalBridgeBackend+ChannelStopped.swift`) and
    ///   `disconnect()` itself (`LocalBridgeBackend.swift`: `guard isConnected
    ///   else { return }; isConnected = false`). Neither runs during ordinary
    ///   auto-retry: `channelStopped(_:)`'s own doc comment says it is reached
    ///   only for a **terminal** failure - never for `.reconnecting`, because a
    ///   recoverable failure no longer stops the channel at all since task 3 of
    ///   the reconnect taxonomy - and `disconnect()` is a deliberate call
    ///   nothing in the automatic retry path makes on its own.
    ///   `ConnectionBanner.offersReconnect(for:)` only ever returns `true` for
    ///   `.reconnecting`. So the one state this button could be drawn in is
    ///   exactly the state where nothing has touched `isConnected` since the
    ///   original successful `connect()` - it is still `true`, and a fresh
    ///   `connect()` call returns instantly, having done nothing. A button that
    ///   silently does nothing is a worse affordance than no button.
    /// - **`disconnect()` then `connect()` would use only existing members,
    ///   and still is not obviously safe.** `ChatBackend`'s own contract
    ///   allows a stream to survive a disconnect/reconnect cycle, so this
    ///   composition is not forbidden by anything upstream. But
    ///   `connect()`'s first step, `Bootstrap.run(cookies:endpoints:)`
    ///   (`GChatBridgeCore/Session/Bootstrap.swift`), is one HTTP round trip
    ///   with no retry of its own, and nothing in `connect()` schedules
    ///   another attempt if that throws. Tearing down the channel's own
    ///   indefinitely-retrying loop via `disconnect()` and then hitting a
    ///   `connect()` that itself fails - plausible exactly when someone
    ///   impatiently mashes "reconnect now" while the network is still bad -
    ///   would leave the backend fully stopped with nothing left auto-
    ///   retrying. That reintroduces, one layer higher, the "an outage longer
    ///   than roughly eight seconds was permanent until relaunch" bug
    ///   `ChannelSession`'s own doc comment says task 3 fixed.
    ///
    /// A version of this button that is both safe and useful needs `connect()`
    /// itself to tolerate its own failure (or a narrower primitive that only
    /// nudges the existing channel's backoff without tearing anything down) -
    /// genuinely new `ChatBackend` surface, and out of scope here. Leaving
    /// this `nil` means `StatusStrip` draws no control and the reducer's
    /// unconditional retry stays the only recovery path, which is the part
    /// that was actually asked for.
    var actions: ChatSceneActions {
        ChatSceneActions(
            select: { [weak self] id in
                guard case let .running(model) = self?.phase else { return }
                model.select(id)
            },
            send: { [weak self] message in
                guard case let .running(model) = self?.phase else { return }
                model.send(message)
            },
            // Offered **only** from `.failed`, which is the phase that had no
            // way out. `.needsSignIn` already shows the capture window,
            // `.running` must not invite someone to re-authenticate a working
            // session over one transient banner, and a probe report is not a
            // session problem at all.
            signIn: isFailed ? { [weak self] in self?.requestSignIn() } : nil,
            draftRestored: { [weak self] in
                guard case let .running(model) = self?.phase else { return }
                model.clearFailedDraft()
            },
            mute: canEditNotificationRules ? { [weak self] in self?.settings.mute($0) } : nil,
            unmute: canEditNotificationRules ? { [weak self] in self?.settings.unmute($0) } : nil,
            // Needs the account too: until it is identified the receipts gate
            // withholds every mark, and the item would do nothing.
            markRead: canEditNotificationRules && runningModel?.capabilities.canMarkRead == true
                ? { [weak self] in self?.runningModel?.markRead($0, from: .conversationList) }
                : nil,
            // Offered only while a session runs: before that there is nothing to list.
            showMentions: runningModel == nil ? nil : { [weak self] in self?.runningModel?.showMentions() },
            openMention: runningModel == nil ? nil : { [weak self] conversation, message in
                self?.runningModel?.open(conversation: conversation, message: message)
            },
            loadAttachment: canFetchAttachments ? { [weak self] attachment, size in
                guard let self else { throw NoSession() }
                return try await loadAttachment(attachment, size: size)
            } : nil,
            openAttachment: canFetchAttachments ? { [weak self] attachment in
                guard let self else { throw NoSession() }
                return try await openAttachment(attachment)
            } : nil,
            attachmentFiles: attachmentFileActions,
            reactions: runningModel?.capabilities.canReact == true
                ? ReactionActions(
                    toggle: { [weak self] message, choice, add in
                        self?.runningModel?.react(to: message, with: choice, add: add)
                    },
                    customImage: canFetchCustomEmoji ? { [weak self] emoji in
                        guard let self else { throw NoSession() }
                        return try await loadCustomEmoji(emoji)
                    } : nil,
                    recents: { [weak self] in self?.runningModel?.recentReactions(limit: 24) ?? [] },
                    customCatalog: { [weak self] in self?.runningModel?.storedCustomEmoji() ?? [] },
                    skinTone: skinTone,
                    setSkinTone: { [weak self] in self?.setSkinTone($0) }
                )
                : nil,
            composerAttachments: composerAttachmentActions,
            directoryQuery: { [weak self] query in self?.runningModel?.directoryQuery(query) },
            memberPicked: { [weak self] member in self?.runningModel?.checkMembership(member) },
            nonMembers: { [weak self] message in
                await self?.runningModel?.nonMembers(in: message) ?? []
            },
            sendTo: { [weak self] message, conversation in
                self?.runningModel?.send(message, in: conversation)
            },
            keepDraft: { [weak self] message, conversation in
                self?.runningModel?.keepDraft(message, in: conversation)
            },
            // One struct for both: `ChatWindow` draws each item only for its
            // own capability (edit spec §5).
            messages: runningModel
                .map { $0.capabilities.canEditMessages || $0.capabilities.canDeleteMessages }
                == true
                ? MessageActions(
                    save: { [weak self] id, message in self?.runningModel?.edit(id, to: message) },
                    delete: { [weak self] id in self?.runningModel?.delete(id) }
                )
                : nil
        )
    }

    private var isFailed: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }
}

import ChatKit
import SwiftUI

/// `MessageList`'s rows, older paging near the top, and what it notes about
/// arrivals. Its own file so `MessageList.swift` stays under `file_length`.
extension MessageList {
    /// What `TranscriptFollowing` reads when the geometry changes.
    func followConditions() -> TranscriptFollowing.Conditions {
        TranscriptFollowing.Conditions(
            canFollow: !state.hasNewerMessages,
            settled: hasPlacedMessages && readingAnchor.restoringID == nil && !latestJumpRequested
        )
    }

    /// One message's bubble, where `TranscriptGrouping` placed it.
    func bubble(
        _ message: Message, placement: TranscriptRowPlacement, marker: ReadReceiptMarker?
    ) -> some View {
        MessageBubble(
            message: message,
            state: MessageRowState(
                message: message, scene: state, showsThread: threads != nil, downloads: downloads,
                badgesSender: placement.endsGroup && message.sender != state.me
            ),
            receiptDirectory: marker?.messageID == message.id
                ? RowDirectory.avatars(marker?.readers ?? [], in: state.directory) : [:],
            receiptReaders: marker?.messageID == message.id ? marker?.readers ?? [] : [],
            receiptSlot: state.capabilities.receivesReadReceipts,
            groupReceipt: state.selectedConversation?.kind != .directMessage,
            loadAttachment: loadAttachment, openAttachment: openAttachment,
            loadRemoteImage: loadRemoteImage,
            attachmentFiles: attachmentFiles,
            reactions: reactions, own: own, openThread: threads?.open,
            marked: marked?.id, markOn: markOn, checkDelivery: checkMessageDelivery,
            continuesGroup: placement.continuesGroup, endsGroup: placement.endsGroup,
            datedBySeparator: true
        )
    }

    /// Older messages load as the person scrolls up near the top, with no
    /// button to press, and at once while the messages do not fill the
    /// transcript, when there is nothing to scroll. `pageIfNeeded` keeps one
    /// page in flight and never asks twice from the same first message.
    ///
    /// The visible-rows rule (`TranscriptPaging`) covers most scrolling; this
    /// covers what it cannot see: scrolling up while the first rows are
    /// already the ones in view.
    func pageOlderNearTheTop(from old: TranscriptTop, to new: TranscriptTop) {
        guard hasPlacedMessages, state.hasOlderMessages else { return }
        if !new.fills {
            pageIfNeeded(.older)
        } else if paging.hasUserIntent, new.offset < old.offset,
                  new.offset < TranscriptTop.pagingDistance {
            pageIfNeeded(.older)
        }
    }

    /// Someone else's message arriving while the newest end is out of view
    /// turns the jump button into New Messages. A page of newer history, a
    /// trimmed window and your own message are not arrivals.
    func noteArrival(from old: Message.ID?, to new: Message.ID?) {
        let fromPage = old != nil && old == newerPageFrom
        if fromPage {
            newerPageFrom = nil
        }
        let following = follow.isFollowing && !state.hasNewerMessages
        if TranscriptArrival.isUnseen(
            from: old, to: new, messages: state.messages, me: state.me,
            expected: following || fromPage || latestJumpRequested
        ) {
            unseenArrivals = true
        }
    }
}

/// Whether a change to the newest message is someone's new message the
/// person has not seen: pure, so each rule is a test.
enum TranscriptArrival {
    /// `old` and `new` are the newest message before and after. Only an
    /// arrival counts: `old` is still there and `new` is now last, from
    /// someone else. `expected` is a change the person already sees or asked
    /// for: the transcript following the newest end, or a page of history.
    static func isUnseen(
        from old: Message.ID?, to new: Message.ID?, messages: [Message], me: Member.ID?, expected: Bool
    ) -> Bool {
        guard let old, let new, old != new, !expected,
              let last = messages.last, last.id == new, last.sender != me
        else { return false }
        return messages.contains { $0.id == old }
    }
}

/// Where the transcript's viewport is against the top of its content, read
/// from the scroll view's geometry for older paging.
struct TranscriptTop: Equatable {
    /// How far the viewport's top is below the content's.
    var offset: CGFloat
    /// Whether the content is taller than the viewport.
    var fills: Bool

    /// Older messages are asked for once the viewport's top comes within
    /// this of the content's, scrolling up: about a screenful early, so the
    /// page usually lands before the person reaches it.
    static let pagingDistance: CGFloat = 600

    init(offset: CGFloat, fills: Bool) {
        self.offset = offset
        self.fills = fills
    }

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y + geometry.contentInsets.top
        fills = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            > geometry.containerSize.height + 1
    }
}

/// What `MessageList`'s mark watches: the message a search opened, the open
/// that opened it, and whether the transcript has loaded it yet. `loaded` is
/// the count rather than the message ids, so the trigger stays cheap to
/// compare and still fires once the target's page lands.
struct TranscriptMarkTrigger: Equatable {
    let target: Message.ID?
    let generation: Int
    let loaded: Int

    init(_ state: ChatSceneState) {
        target = state.highlightedMessage
        generation = state.searchOpenGeneration
        loaded = state.messages.count
    }
}

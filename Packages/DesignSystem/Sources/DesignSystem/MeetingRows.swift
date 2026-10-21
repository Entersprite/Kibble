import ChatKit
import Foundation
import SwiftUI

struct MeetingPicture: View {
    var size: CGFloat = 20

    var body: some View {
        MonogramCircle(size: size) {
            Image(systemName: "video.fill").font(.system(size: size * 0.45))
        }
    }
}

/// Only row-relevant values reach list children, including aggregate series state.
struct ConversationItemRowState: Equatable {
    let conversation: Conversation
    let title: String
    let detail: String?
    let lastActivity: Date?
    let showsUnread: Bool
    let dimmed: Bool
    let muted: Bool

    init(item: SidebarItem, scene: ChatSceneState) {
        let originals: [Conversation]
        switch item {
        case let .conversation(value):
            conversation = value
            originals = [value]
            detail = Display.memberCountLabel(of: value)
        case let .meeting(series):
            conversation = series.latest
            originals = series.occurrences
            let count = series.occurrences.count
            let meetings = "\(count) \(count == 1 ? "meeting" : "meetings")"
            detail = [Display.memberCountLabel(of: series.latest), meetings].compactMap(\.self)
                .joined(separator: " · ")
        }
        title = item.title(directory: scene.directory, me: scene.me)
        lastActivity = item.lastActivity
        showsUnread = originals.contains {
            ThreadsPresentation.showsUnread($0, hidden: scene.unreadHidden.contains($0.id))
        }
        dimmed = originals.allSatisfy { scene.dimmed.contains($0.id) }
        muted = originals.allSatisfy { $0.isMuted || scene.muted.contains($0.id) }
    }
}

struct MeetingSeriesRow: View {
    let row: ConversationItemRowState
    /// The picture follows the person's sidebar icon size, as `ConversationRow`'s does.
    @Environment(\.sidebarRowSize) private var rowSize

    init(series: MeetingSeries, state: ChatSceneState) {
        row = ConversationItemRowState(item: .meeting(series), scene: state)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(row.title).lineLimit(1).fontWeight(row.showsUnread ? .semibold : .regular)
            } icon: {
                MeetingPicture(size: SidebarRowPicture.diameter(rowSize)).accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            if row.muted {
                Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.tertiary)
            }
            if row.showsUnread {
                Circle().fill(.tint).frame(width: 7, height: 7).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 1)
        .opacity(row.dimmed ? 0.55 : 1)
    }
}

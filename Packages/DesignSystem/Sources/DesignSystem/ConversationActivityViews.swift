import ChatKit
import SwiftUI

struct TypingIndicator: View {
    let members: [Member.ID]
    let directory: [Member.ID: Member]
    let namesVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var description: String {
        let names = members.prefix(2).map { directory[$0]?.displayName ?? "Someone" }
        if members.count > 2 {
            return "Several people are typing…"
        }
        return names.joined(separator: " and ") + (members.count == 1 ? " is typing…" : " are typing…")
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0 ..< 3) { index in
                    if reduceMotion {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                    } else {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                            .phaseAnimator([false, true]) { dot, phase in
                                dot.opacity(phase ? 1 : 0.35)
                            } animation: { _ in
                                .easeInOut(duration: 0.6).delay(Double(index) * 0.15)
                            }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            if namesVisible {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .onAppear { AccessibilityNotification.Announcement(description).post() }
        .onChange(of: members) { _, _ in AccessibilityNotification.Announcement(description).post() }
    }
}

struct ReadReceiptLabel: View {
    let readers: [Member.ID]
    let directory: [Member.ID: Member]
    let group: Bool
    @State private var showingReaders = false

    var body: some View {
        Group {
            if group {
                Button("Read by \(readers.count)") { showingReaders.toggle() }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show readers")
                    .popover(isPresented: $showingReaders) { readerList }
            } else {
                Text("Read")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var readerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read by \(readers.count)").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(readers, id: \.self) { member in
                        HStack(spacing: 8) {
                            Avatar(member: member, directory: directory, size: 26)
                            Text(directory[member]?.displayName ?? "Someone")
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(readers.count) * 36, 260))
        }
        .padding(16).frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
    }
}

enum ActivityPresentation {
    static func typists(_ state: ChatSceneState, thread: MessageThread.ID? = nil) -> [Member.ID] {
        guard state.capabilities.receivesTypingState else { return [] }
        return Array(Set(state.activity.typing.filter {
            $0.threadID == thread && $0.member != state.me
        }.map(\.member))).sorted { $0.rawValue < $1.rawValue }
    }

    static func marker(_ state: ChatSceneState) -> ReadReceiptMarker? {
        guard state.capabilities.receivesReadReceipts,
              state.activity.receiptsEnabled == true else { return nil }
        return ReadReceiptMarker.latest(
            in: state.messages,
            positions: state.activity.receipts,
            me: state.me,
            excluding: state.pendingMessages
        )
    }
}

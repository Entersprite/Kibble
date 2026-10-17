import SwiftUI

struct MeetingMetadataProgress: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Organizing meeting chats…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

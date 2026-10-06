import SwiftUI

/// "Editing message ✕" above the field (edit spec §5).
struct ComposerEditBar: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label("Editing message", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: cancel) {
                Label("Cancel Editing", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel Editing (Esc)")
        }
        .padding(.horizontal, 6)
    }
}

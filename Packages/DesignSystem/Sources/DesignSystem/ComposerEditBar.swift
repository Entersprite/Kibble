import SwiftUI

/// "Editing message ✓ ✕" above the field (edit spec §5). On the Mac the ✓
/// saves, as Return does: with no send button there, it is the one way to
/// save with the mouse, as in Messages' own edit (session 59).
struct ComposerEditBar: View {
    /// Return would save: the edit is not empty.
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label("Editing message", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            // The Mac only: elsewhere the send arrow saves (review finding 7).
            #if os(macOS)
                Button(action: save) {
                    Label("Save Edit", systemImage: ComposerLayout.saveSymbol)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(canSave ? AnyShapeStyle(Color.accentColor) :
                            AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .help("Save Edit (Return)")
            #endif
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

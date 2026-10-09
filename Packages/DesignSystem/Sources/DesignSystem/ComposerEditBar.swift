import SwiftUI

/// "Editing message ✓ ✕" above the field (edit spec §5). The ✓ saves, as
/// Return does: with no send button on the Mac, it is the one way to save
/// with the mouse, as in Messages' own edit (session 59).
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
            Button(action: save) {
                Label("Save Edit", systemImage: ComposerLayout.saveSymbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(canSave ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .help("Save Edit (Return)")
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

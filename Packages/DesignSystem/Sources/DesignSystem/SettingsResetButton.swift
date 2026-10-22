import SwiftUI

/// Native confirmation with the target and action captured when asked, so
/// changing a Settings account cannot retarget an already open alert.
public struct SettingsResetButton: View {
    private let title: String
    private let message: String
    private let isDeletion: Bool
    private let action: () -> Void
    @State private var pending: Confirmation?

    private struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: () -> Void
    }

    public init(
        title: String = "Reset to Defaults…", message: String,
        isDeletion: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.isDeletion = isDeletion
        self.action = action
    }

    public var body: some View {
        Button(title, role: isDeletion ? .destructive : nil) {
            pending = Confirmation(
                title: isDeletion ? "Delete All User Data?" : "Reset to Defaults?",
                message: message, action: action
            )
        }
        .alert(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }
        ), presenting: pending) { confirmation in
            Button(isDeletion ? "Delete All User Data" : "Reset", role: .destructive) {
                confirmation.action()
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

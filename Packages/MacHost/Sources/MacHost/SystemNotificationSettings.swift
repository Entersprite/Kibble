import AppKit
import SwiftUI

/// The pane in System Settings where banner-versus-alert style lives - the
/// one delivery choice an app cannot make itself (spec §1).
public enum SystemNotificationSettings {
    /// `[Verify]` on macOS 26: Apple documents no stable URL for this pane.
    /// Task 9's live check confirms it opens the right place.
    static let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    @MainActor
    public static func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The Dock tile's number. Needs no notification permission.
enum DockBadge {
    @MainActor
    static func show(_ count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}

/// The sign-out confirmation, shared by the main window and the Settings
/// window so the promise it makes is written once.
struct SignOutConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let signOut: () -> Void

    static let message = "This Mac will forget this session and its local message history. "
        + "Your notification settings are kept for when you sign in again. "
        + "This does not sign you out of Google - your session stays valid there until it expires on its own."

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Sign out of GChat?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: signOut)
        } message: {
            Text(Self.message)
        }
    }
}

public extension View {
    func signOutConfirmation(isPresented: Binding<Bool>, signOut: @escaping () -> Void) -> some View {
        modifier(SignOutConfirmation(isPresented: isPresented, signOut: signOut))
    }
}

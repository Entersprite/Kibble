import ChatKit
import SwiftUI

/// Who is signed in, and the way to your account and the app's settings - the
/// sidebar's fixed bottom row.
///
/// Drawn only when `actions.signOut` is offered, the same rule `StatusStrip`
/// already applies to `actions.signIn`: a host with no running session has
/// nothing to sign out of, so this draws nothing rather than a menu that
/// does nothing. That also keeps this from ever showing a half-built
/// identity next to a control that cannot act on it - there is no running
/// session either way.
struct SidebarFooter: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    /// The height of both glass controls, your account and the gear, so the
    /// two line up.
    static let controlSize: CGFloat = 36
    static let avatarSize: CGFloat = 28
    /// The avatar's inset from the capsule's edge on every side, so its circle
    /// sits concentric with the capsule's rounded end.
    static let avatarInset = (controlSize - avatarSize) / 2

    var body: some View {
        if actions.signOut != nil {
            // No `Divider()` and no tinted background: both existed to fake a
            // separation `safeAreaBar` now provides, and keeping them would
            // draw it twice.
            // Redrawn at your own boundaries, like a DM row (spec §6.3), and when Do not disturb ends.
            TimelineView(.explicit(Display.ownRedrawDates(
                for: state.me.flatMap { state.directory[$0] },
                availability: state.availability,
                now: .now
            ))) { _ in
                HStack(spacing: 10) {
                    // Your status and Sign Out… (`AccountMenu`). Sign Out is a
                    // menu item rather than a button here: an accidental click
                    // costs a full two-factor login.
                    OwnAccountMenu(state: state, actions: actions) {
                        HStack(spacing: 8) { identity }
                            .padding(.leading, Self.avatarInset)
                            .padding(.trailing, 12)
                            .frame(height: Self.controlSize)
                            .contentShape(.capsule)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    Spacer(minLength: 8)
                    ownMarks
                    if let showSettings = actions.showSettings {
                        RoundGlassButton(
                            title: "Settings", systemImage: "gearshape", diameter: Self.controlSize,
                            action: showSettings
                        )
                    }
                }
            }
            // 12 plus the capsule's inset puts your avatar in the rows' avatar
            // column; 10 keeps the footer as tall as it was with 28-point controls.
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// `Display.signedInLabel` already decides what to show when `state.me`
    /// has not resolved yet - see its own doc comment - so this only has to
    /// draw an avatar or a neutral stand-in for the same gap.
    @ViewBuilder private var identity: some View {
        if let me = state.me {
            Avatar(
                member: me, directory: state.directory, size: Self.avatarSize,
                presence: Display.ownPresence(
                    availability: state.availability, directory: state.directory, me: me,
                    connection: state.connection, now: .now
                )
            )
        } else {
            UnknownPersonGlyph(size: Self.avatarSize)
        }
        Text(Display.signedInLabel(me: state.me, directory: state.directory))
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.primary)
    }

    /// Your own status and calendar marks, the one place they are drawn
    /// (spec §6.2): at the trailing edge, beside the gear, as a DM row's are.
    @ViewBuilder private var ownMarks: some View {
        if let marks = PersonMarks(
            status: Display.ownStatus(
                directory: state.directory, me: state.me, connection: state.connection, now: .now
            ),
            calendar: Display.ownCalendar(
                directory: state.directory, me: state.me, connection: state.connection, now: .now
            ),
            now: .now
        ) {
            marks
        }
    }
}

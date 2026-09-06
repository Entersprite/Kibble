import ChatKit
import SwiftUI

/// A person, drawn the way macOS Messages draws one.
///
/// Three rungs, picked in Messages' own order: a real photo when the directory
/// carries one, initials when a name resolved, and Apple's own
/// `person.crop.circle.fill` when nothing did.
///
/// There is deliberately **no colour per person**. Messages draws every
/// monogram in one muted grey, and the eight-colour hashed palette this
/// replaced - `AvatarPalette`, deleted with this change - was the single
/// biggest reason the sidebar did not read as native.
public struct Avatar: View {
    let member: Member.ID
    let directory: [Member.ID: Member]
    var size: CGFloat = 26

    public init(member: Member.ID, directory: [Member.ID: Member], size: CGFloat = 26) {
        self.member = member
        self.directory = directory
        self.size = size
    }

    public var body: some View {
        if let url = directory[member]?.avatarURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                // The same thing the no-photo path draws, so a slow load - or a
                // URL the server will not serve us - degrades to initials
                // rather than to a hole where a face should be.
                fallback
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallback
        }
    }

    /// Initials when somebody has told us a name, Apple's glyph when nobody has.
    @ViewBuilder private var fallback: some View {
        if Display.hasName(of: member, in: directory) {
            MonogramCircle(size: size) {
                Text(Display.initials(of: member, in: directory))
                    .font(.system(size: size * 0.4, weight: .semibold))
            }
        } else {
            UnknownPersonGlyph(size: size)
        }
    }
}

/// Somebody nobody has named yet - the bare-phone-number rows in Messages.
///
/// Palette rendering gets the white figure and the grey disc out of one stock
/// symbol, rather than a circle and an overlay that have to be kept in step
/// with each other by hand.
struct UnknownPersonGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, AvatarStyle.monogram)
            .frame(width: size, height: size)
    }
}

/// The grey disc every non-photo avatar sits on, and the one place its content
/// is centred and tinted.
///
/// Shared with `ConversationRow`'s group icon so the sidebar's discs cannot
/// drift away from the transcript's.
struct MonogramCircle<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        Circle()
            .fill(AvatarStyle.monogram)
            .frame(width: size, height: size)
            .overlay { content.foregroundStyle(.white) }
    }
}

/// The one fill here that cannot come from the system.
///
/// Messages' monogram grey is not vended by any public API, and a dynamic
/// `NSColor`/`UIColor` provider is barred in this package because it builds for
/// both platforms and neither type exists on the other - so it is stated once
/// here rather than spelled at each call site.
///
/// It is a **gradient, not a flat fill**: Messages shades its discs from top to
/// bottom, and a flat circle is noticeably deader beside a real one.
///
/// **One gradient, both appearances.** These are the owner's own values; an
/// earlier version carried a second, lighter pair for light mode, and picking
/// between them was the only reason anything here read
/// `@Environment(\.colorScheme)`. Dropping it takes the environment read out of
/// `MonogramCircle` and `UnknownPersonGlyph` too.
enum AvatarStyle {
    /// `#6A657A` to `#3F365A`.
    static let monogram = LinearGradient(
        colors: [
            Color(red: 0x6A / 255, green: 0x65 / 255, blue: 0x7A / 255),
            Color(red: 0x3F / 255, green: 0x36 / 255, blue: 0x5A / 255)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

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
///
/// Presence is opt-in, by initialiser, and passed in rather than read from
/// `directory`: the caller decides whether this avatar is one that shows it
/// (`Display.presence(of:directory:me:connection:)`), so a transcript full of
/// senders does not grow a dot each - nor pay for the badge's mask.
public struct Avatar: View {
    let member: Member.ID
    let directory: [Member.ID: Member]
    var size: CGFloat = 26
    /// Set by the initialiser, never by the value: whether this call site
    /// shows presence at all. Constant per call site, so a presence arriving
    /// or leaving never changes the view's structure.
    private let badged: Bool
    private var presence: Presence?

    public init(member: Member.ID, directory: [Member.ID: Member], size: CGFloat = 26) {
        self.member = member
        self.directory = directory
        self.size = size
        badged = false
    }

    /// An avatar that shows `presence` as a badge, and nothing while it is `nil`.
    public init(member: Member.ID, directory: [Member.ID: Member], size: CGFloat = 26, presence: Presence?) {
        self.member = member
        self.directory = directory
        self.size = size
        badged = true
        self.presence = presence
    }

    /// Where `badged`, the mask and the overlay are always there, empty
    /// without a badge, so a presence change never alters the view's
    /// structure - which would rebuild the `AsyncImage` and refetch the photo.
    /// Elsewhere there is no mask at all: it costs an offscreen pass per
    /// avatar, and a transcript has many.
    public var body: some View {
        if badged {
            face
                .mask { PresenceBadge.cutout(for: presence, avatarSize: size) }
                .overlay(alignment: .bottomTrailing) {
                    if let presence {
                        PresenceBadge(presence: presence, avatarSize: size)
                    }
                }
        } else {
            face
        }
    }

    @ViewBuilder private var face: some View {
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

/// A presence dot on an avatar's bottom-trailing edge, in a gap cut out of
/// the face.
///
/// **Cut out, not ringed in a colour.** A ring filled with `.background`
/// matches nothing the avatar sits on: the sidebar is a material, and in
/// dark mode the fill drew as a grey halo. Rendering showed it; no test
/// could have. The gap shows whatever is really behind the avatar.
///
/// Shapes rather than SF Symbols, so there is no symbol name to get wrong
/// (`CLAUDE.md`: a wrong one compiles and renders as empty space). Green for
/// active, a hollow ring for away, red with a bar for do not disturb - the
/// usual vocabulary; how Google's own client draws them is `[Verify]`.
/// Nothing for `.unknown`, which `Display.presence` already filters.
struct PresenceBadge: View {
    let presence: Presence
    let avatarSize: CGFloat

    static func diameter(_ avatarSize: CGFloat) -> CGFloat {
        max(7, (avatarSize * 0.36).rounded())
    }

    static func gap(_ avatarSize: CGFloat) -> CGFloat {
        max(1.5, diameter(avatarSize) * 0.2)
    }

    /// Puts the badge's centre on the face's circle at 45 degrees, rather
    /// than inside the corner of its square, so it covers less of the
    /// initials. `0.146` is `(1 - 1/sqrt(2)) / 2`: how far that point sits
    /// in from the square's corner, per unit of size.
    static func offset(_ avatarSize: CGFloat) -> CGFloat {
        max(0, diameter(avatarSize) / 2 - avatarSize * 0.146)
    }

    /// The face's mask: all of it, less a circle around where a badge goes.
    /// Empty of any hole when there is no badge to draw.
    @ViewBuilder static func cutout(for presence: Presence?, avatarSize: CGFloat) -> some View {
        let hole = diameter(avatarSize) + gap(avatarSize) * 2
        Rectangle()
            .overlay(alignment: .bottomTrailing) {
                if let presence, Display.presenceLabel(presence) != nil {
                    Circle()
                        .frame(width: hole, height: hole)
                        .offset(
                            x: offset(avatarSize) + gap(avatarSize),
                            y: offset(avatarSize) + gap(avatarSize)
                        )
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }

    var body: some View {
        if let label = Display.presenceLabel(presence) {
            let diameter = Self.diameter(avatarSize)
            mark(diameter)
                .frame(width: diameter, height: diameter)
                .offset(x: Self.offset(avatarSize), y: Self.offset(avatarSize))
                .accessibilityElement()
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder private func mark(_ diameter: CGFloat) -> some View {
        switch presence {
        case .active:
            Circle().fill(.green)
        case .inactive:
            Circle().strokeBorder(.secondary, lineWidth: max(1.5, diameter * 0.22))
        case .doNotDisturb:
            Circle().fill(.red).overlay {
                Capsule().fill(.white).frame(width: diameter * 0.55, height: max(1.5, diameter * 0.2))
            }
        case .unknown:
            EmptyView()
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

import ChatKit
import SwiftUI

/// A person, as a coloured circle with their initials.
public struct Avatar: View {
    private static let colors: [Color] = [
        Color(red: 0.49, green: 0.36, blue: 0.75),
        Color(red: 0.70, green: 0.33, blue: 0.18),
        Color(red: 0.18, green: 0.49, blue: 0.42),
        Color(red: 0.36, green: 0.48, blue: 0.60),
        Color(red: 0.20, green: 0.31, blue: 0.49),
        Color(red: 0.60, green: 0.30, blue: 0.45),
        Color(red: 0.30, green: 0.45, blue: 0.25),
        Color(red: 0.55, green: 0.45, blue: 0.15)
    ]

    let member: Member.ID
    let directory: [Member.ID: Member]
    var size: CGFloat = 26

    public init(member: Member.ID, directory: [Member.ID: Member], size: CGFloat = 26) {
        self.member = member
        self.directory = directory
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Self.colors[AvatarPalette.index(for: member.rawValue, count: Self.colors.count)])
            .frame(width: size, height: size)
            .overlay {
                Text(Display.initials(of: member, in: directory))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if let presence = directory[member]?.presence {
                    PresenceDot(presence: presence, size: size * 0.3)
                }
            }
    }
}

private struct PresenceDot: View {
    let presence: Presence
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            // `.background` as a shape style rather than a named platform
            // colour: this package builds for iOS too, and NSColor does not.
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }

    /// An unknown presence draws nothing rather than guessing at a colour: the
    /// enum is open, and a state this build has never seen is not necessarily
    /// "away".
    private var color: Color {
        switch presence {
        case .active: .green
        case .inactive: .orange
        case .doNotDisturb: .red
        case .unknown: .clear
        }
    }
}

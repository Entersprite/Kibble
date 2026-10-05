import DesignSystem
import Foundation

/// The reaction skin tone's persistence: one app-wide value in the app's
/// defaults (reactions spec §3), offered to the picker through
/// `ReactionActions`.
extension AppEnvironment {
    static let skinToneKey = "reactionSkinTone"

    func setSkinTone(_ tone: SkinTone) {
        skinTone = tone
        preferences.set(tone.rawValue, forKey: Self.skinToneKey)
    }
}

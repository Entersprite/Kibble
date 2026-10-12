import DesignSystem
import Foundation

/// The reaction picker writes only for an identified account.
extension AppEnvironment {
    static let skinToneKey = "reactionSkinTone"

    func setSkinTone(_ tone: SkinTone) {
        guard settings.account != nil else { return }
        skinTone = tone
        savePersonalPreferences()
    }
}

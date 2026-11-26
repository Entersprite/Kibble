import Foundation

enum AppSound: String, CaseIterable {
    case connecting, fetch, hangup, ringing
    case ringtone = "Kibble"
    case alternateRingtone = "KibbleAlt"
    case newMessage = "new-message"
    case personJoined = "person-joined"
    case personLeft = "person-left"

    var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "aif")
    }
}

@MainActor
enum MessageSoundFeedback {
    private static let player = RingtonePlayer()

    static func sending() {
        guard let url = AppSound.fetch.url else { return }
        try? player.play(url, loops: false)
    }
}

public extension SystemLaunchServices {
    func messageSending() {
        MessageSoundFeedback.sending()
    }
}

extension ServiceAccountLaunchServices {
    func messageSending() {
        MessageSoundFeedback.sending()
    }
}

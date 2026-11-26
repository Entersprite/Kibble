#if DEBUG
    import Foundation
    import UserNotifications

    /// A local-only sound check: no account, credentials, store or provider starts.
    @MainActor
    enum NotificationSoundProbe {
        static func run() async -> String {
            var lines = ["Bundled message cue: \(AppSound.newMessage.url != nil)"]
            do {
                try MessageNotificationSound.install()
                lines.append("Sound installation: succeeded")
                let library = try MessageNotificationSound.libraryDirectory()
                let installed = library.appendingPathComponent("Sounds/" + MessageNotificationSound.filename)
                guard let sourceURL = AppSound.newMessage.url else { throw CocoaError(.fileNoSuchFile) }
                let source = try Data(contentsOf: sourceURL)
                try lines.append("Installed cue matches bundle: \(Data(contentsOf: installed) == source)")
            } catch {
                let error = error as NSError
                lines.append("Sound installation: \(error.domain) \(error.code)")
            }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            lines.append("Notification authorization: \(settings.authorizationStatus.rawValue)")
            lines.append("Sounds setting: \(settings.soundSetting.rawValue)")
            let previous = await center.deliveredNotifications().map(\.request.identifier)
                .filter { $0.hasPrefix("kibble.notification-sound-check") }
            center.removeDeliveredNotifications(withIdentifiers: previous)
            let content = UNMutableNotificationContent()
            content.title = "Kibble sound check"
            content.body = "This notification uses the new message sound."
            content.sound = MessageNotificationSound.sound
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "kibble.notification-sound-check", content: content, trigger: nil
                ))
                lines.append("Sound check notification: submitted")
            } catch {
                let error = error as NSError
                lines.append("Sound check notification: \(error.domain) \(error.code)")
            }
            let report = lines.joined(separator: "\n")
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
            return report
        }
    }
#endif

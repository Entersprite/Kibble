import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallCaptionSelectionTests {
    @Test func aNewCatalogOrSourceReplacesAnUnavailableTranslation() {
        let languages = CallCaptionLanguages(live: ["hu-HU"], translations: [
            "hu-HU": ["sk-SK"], "ja-JP": ["fr-FR"]
        ])
        let old = CallCaptionSelection(spoken: "de-DE", translated: "fr-FR")
        #expect(old.resolved(in: languages).display == "hu-HU")
        let valid = CallCaptionSelection(spoken: "hu-HU", translated: "sk-SK")
        #expect(valid.resolved(in: languages).display == "sk-SK")
        let changedSource = CallCaptionSelection(spoken: "ja-JP", translated: "sk-SK")
        let resolved = changedSource.resolved(in: languages)
        #expect(resolved.spoken == "ja-JP" && resolved.display == "fr-FR")
        #expect(languages.supports(spoken: resolved.spoken, display: resolved.display))
    }

    @Test func theNativeControlsRenderWithMeetingSpecificChoices() throws {
        let languages = CallCaptionLanguages(live: ["hu-HU"], translations: ["hu-HU": ["sk-SK"]])
        // The controls are a section of rows; a grouped form is their container.
        let view = Form {
            CallCaptionControls(settings: nil, languages: languages) { _ in }
            CallCaptionControls(
                settings: CallCaptionState(spokenLanguage: "hu-HU", displayLanguage: "hu-HU"),
                languages: languages
            ) { _ in }
            CallHostSettingsView(
                settings: CallHostSettings(
                    managementEnabled: true, reactionsAllowed: true, chatMessagesAllowed: true,
                    screenSharingAllowed: false, microphoneAllowed: true, cameraAllowed: true,
                    joiningBeforeHostAllowed: false, waitingRoomEnabled: false,
                    meetingAccess: CallMeetingAccess(
                        preset: "trusted", availablePresets: ["open", "trusted", "restricted"],
                        joinRequestsAllowed: true
                    )
                ),
                availableActions: [
                    "hostManagement", "allowJoinRequests", "allowJoiningBeforeHost", "allowChatMessages",
                    "allowScreenSharing", "allowReactions", "setMeetingAccess", "endConference"
                ],
                submit: { _ in }
            )
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 900)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: 420, height: 900))
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CAPTION_SETTINGS_RENDER_DIR"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("caption-settings.png"))
        }
    }
}

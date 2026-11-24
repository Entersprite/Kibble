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
        let view = CallCaptionControls(settings: nil, languages: languages) { _ in }
            .frame(width: 320, alignment: .leading).padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size.width == 352)
        #expect(host.frame.size.height > 100)
        if let directory = ProcessInfo.processInfo.environment["KIBBLE_CAPTION_SETTINGS_RENDER_DIR"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("caption-settings.png"))
        }
    }
}

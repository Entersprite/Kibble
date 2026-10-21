import Foundation
import Testing
@testable import MacHost

struct EmbeddedMediaPolicyTests {
    @Test func onlySupportedHTTPSPlayersCanLoadAndCarryTheAppsIdentity() throws {
        let url = try #require(URL(string: "https://www.youtube-nocookie.com/embed/abcdefghijk"))
        let request = try #require(EmbeddedMediaPolicy.request(url, bundleID: "com.entersprite.kibble"))
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://com.entersprite.kibble")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        for raw in [
            "http://www.youtube-nocookie.com/embed/abcdefghijk",
            "https://www.youtube-nocookie.com.evil.example/embed/abcdefghijk",
            "https://user:password@www.youtube-nocookie.com/embed/abcdefghijk",
            "https://www.youtube-nocookie.com/watch?v=abcdefghijk",
            "https://www.youtube-nocookie.com/embed/short",
            "https://www.youtube-nocookie.com/embed/abcdefghijk?autoplay=1",
            "file:///embed/abcdefghijk"
        ] {
            let candidate = try #require(URL(string: raw))
            #expect(!EmbeddedMediaPolicy.allows(candidate))
        }
    }

    /// Nothing kept and nothing played unasked; the player's own full-screen
    /// button works.
    @MainActor
    @Test func thePlayerKeepsNoDataAndWaitsForPlay() {
        let configuration = EmbeddedMediaPresenter.configuration()
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(configuration.preferences.isElementFullscreenEnabled)
    }

    @MainActor
    @Test func theWindowResizesFreelyAndStaysOutOfTabs() {
        let window = EmbeddedMediaPresenter.makeWindow()
        // No fixed shape: a portrait or 4:3 video gets a window to match.
        #expect(window.contentAspectRatio == .zero)
        #expect(window.contentMinSize == NSSize(width: 480, height: 270))
        #expect(window.tabbingMode == .disallowed)
        #expect(window.title == "Video")
        #expect(!window.isReleasedWhenClosed)
    }

    @Test func theWindowTakesThePagesTitleOnceThereIsOne() {
        #expect(EmbeddedMediaPolicy.windowTitle(nil) == "Video")
        #expect(EmbeddedMediaPolicy.windowTitle("  ") == "Video")
        #expect(EmbeddedMediaPolicy.windowTitle(" Launch Recap - YouTube\n") == "Launch Recap - YouTube")
    }
}

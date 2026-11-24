import AppKit
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
struct NativeCallAdmissionPromptTests {
    @Test func theNoticeCanBeInspectedWithoutPresentingItsSheet() throws {
        let alert = NativeCallAdmissionPrompt.alert(for: [.recording, .transcription, .notes])
        #expect(alert.buttons.map(\.title) == ["Join", "Cancel"])
        alert.layout()
        let view = try #require(alert.window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["KIBBLE_ADMISSION_NOTICE_RENDER"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func confirmationAndCancellationSettleExactlyOnceWithoutShowingWindows() async throws {
        var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?
        var dismissals = 0
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let prompt = NativeCallAdmissionPrompt(present: { alert, owner, reply in
            #expect(owner === window)
            #expect(alert.informativeText.contains("Recording"))
            #expect(alert.informativeText.contains("Transcription"))
            completion = reply
        }, dismiss: { _, _ in dismissals += 1 })
        let first = Task { await prompt.confirm([.recording, .transcription], in: window) }
        for _ in 0 ..< 100 where completion == nil {
            await Task.yield()
        }
        let accept = try #require(completion)
        accept(.alertFirstButtonReturn)
        #expect(await first.value)
        accept(.alertFirstButtonReturn)
        #expect(dismissals == 1)
        completion = nil
        let second = Task { await prompt.confirm([.recording, .transcription], in: window) }
        for _ in 0 ..< 100 where completion == nil {
            await Task.yield()
        }
        let stale = try #require(completion)
        second.cancel()
        #expect(await second.value == false)
        stale(.alertFirstButtonReturn)
        #expect(dismissals == 2)
    }
}

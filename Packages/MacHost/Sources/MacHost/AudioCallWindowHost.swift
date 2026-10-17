import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// A single call window owned by the app, independent of the main chat window.
@MainActor
public final class AudioCallWindowHost: NSObject, NSWindowDelegate {
    private let actionsForCall: (UUID) -> AudioCallActions
    private let windowClosed: (UUID) -> Void
    private let present: (NSWindow) -> Void
    private let incomingAttention: () -> Void
    private var callID: UUID?
    private var lastWindowRequest: Int?
    private var isClosingSilently = false
    private var showsVideo = false
    private(set) var window: NSWindow?

    public convenience init(
        actions: @escaping (UUID) -> AudioCallActions,
        windowClosed: @escaping (UUID) -> Void
    ) {
        self.init(
            actions: actions,
            windowClosed: windowClosed,
            present: { window in
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            },
            incomingAttention: { NSApp.requestUserAttention(.informationalRequest) }
        )
    }

    /// The injected presentation hook keeps offline tests from showing windows.
    init(
        actions: @escaping (UUID) -> AudioCallActions,
        windowClosed: @escaping (UUID) -> Void,
        present: @escaping (NSWindow) -> Void,
        incomingAttention: @escaping () -> Void = {}
    ) {
        actionsForCall = actions
        self.windowClosed = windowClosed
        self.present = present
        self.incomingAttention = incomingAttention
        super.init()
    }

    public func show() {
        if let window {
            present(window)
        }
    }

    public func update(
        call: AudioCallSnapshot?,
        windowRequests: Int,
        devices: CallAudioDevices? = nil,
        alertsIncoming: Bool = true,
        video: CallVideoController? = nil
    ) {
        guard let call else {
            callID = nil
            lastWindowRequest = nil
            isClosingSilently = true
            window?.close()
            isClosingSilently = false
            return
        }
        let isNewCall = call.id != callID
        let shouldPresent = isNewCall
            ? (call.phase != .incoming || alertsIncoming)
            : windowRequests != lastWindowRequest
        callID = call.id
        lastWindowRequest = windowRequests
        let window = window ?? makeWindow()
        self.window = window
        window.title = video?.camera == nil ? "Audio Call" : "Call"
        let content = NSHostingView(rootView: AudioCallView(
            call: call,
            actions: actionsForCall(call.id),
            devices: devices,
            camera: video?.camera,
            video: video?.camera != nil ? video.map { AnyView(CallVideoSurface(controller: $0)) } : nil,
            screenSharing: video?.screenSharing.state
        ))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        let showsVideo = video?.camera != nil && !call.phase.isTerminal
        if showsVideo != self.showsVideo {
            window.center()
        }
        self.showsVideo = showsVideo
        if shouldPresent {
            present(window)
            if isNewCall, call.phase == .incoming {
                incomingAttention()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosingSilently, let callID else { return }
        windowClosed(callID)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

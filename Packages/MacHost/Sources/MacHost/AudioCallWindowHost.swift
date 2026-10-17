import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// A single call window owned by the app, independent of the main chat window.
///
/// It is drawn like FaceTime's: a dark, borderless-looking stage with the
/// window buttons floating over it. A call starts in the compact audio size
/// and grows into a resizable video window, around its own center, the first
/// time video appears. It stays that size until the call is over, so a camera
/// switched off for a moment does not make the window jump.
@MainActor
public final class AudioCallWindowHost: NSObject, NSWindowDelegate {
    private let actionsForCall: (UUID) -> AudioCallActions
    private let windowClosed: (UUID) -> Void
    private let present: (NSWindow) -> Void
    private let incomingAttention: () -> Void
    private let now: () -> Date
    private var callID: UUID?
    private var lastWindowRequest: Int?
    private var isClosingSilently = false
    private(set) var timing = CallTiming()
    private(set) var layout = CallWindowLayout()
    private(set) var window: NSWindow?
    private var content: NSHostingView<AudioCallView>?

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
        incomingAttention: @escaping () -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        actionsForCall = actions
        self.windowClosed = windowClosed
        self.present = present
        self.incomingAttention = incomingAttention
        self.now = now
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
        video: CallVideoController? = nil,
        person: Member? = nil
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
        if isNewCall {
            timing = CallTiming()
        }
        timing = Self.timing(timing, for: call.phase, now: now)
        let window = window ?? makeWindow()
        self.window = window
        window.title = call.recipient.displayName
        let wasVideo = layout.isVideo
        render(call, in: window, devices: devices, video: video, person: person)
        resize(window, from: wasVideo, isNewCall: isNewCall)
        if shouldPresent {
            present(window)
            if isNewCall, call.phase == .incoming {
                incomingAttention()
            }
        }
    }

    /// Updates the one hosting view in place, so the view keeps its own state
    /// and the video renderers keep their tracks from snapshot to snapshot.
    private func render(
        _ call: AudioCallSnapshot, in window: NSWindow, devices: CallAudioDevices?,
        video: CallVideoController?, person: Member?
    ) {
        let videoContent = video.flatMap(CallVideoSurface.content(for:))
        layout = layout.next(call: call, hasVideo: videoContent?.hasVideo == true)
        var actions = actionsForCall(call.id)
        if call.phase.isTerminal {
            actions.close = { [weak window] in window?.close() }
        }
        let view = AudioCallView(
            call: call,
            actions: actions,
            person: person,
            timing: timing,
            devices: devices,
            camera: video?.camera,
            video: layout.isVideo ? videoContent ?? CallVideoContent() : nil,
            screenSharing: video?.screenSharing.state
        )
        if let content {
            content.rootView = view
        } else {
            let content = NSHostingView(rootView: view)
            window.contentView = content
            self.content = content
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosingSilently, let callID else { return }
        windowClosed(callID)
    }

    /// The connected moment is the first connected snapshot this window saw;
    /// the end is the first finished one after that.
    static func timing(_ timing: CallTiming, for phase: AudioCallPhase, now: () -> Date) -> CallTiming {
        var timing = timing
        if phase == .connected, timing.connectedAt == nil {
            timing.connectedAt = now()
        }
        if phase.isTerminal, timing.connectedAt != nil, timing.endedAt == nil {
            timing.endedAt = now()
        }
        return timing
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CallLayout.compact),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// The audio size follows the content, keeping the top edge where it was.
    /// The video size is set once, on the switch, and is the person's after that.
    private func resize(_ window: NSWindow, from wasVideo: Bool, isNewCall: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        if layout.isVideo {
            guard !wasVideo else { return }
            window.styleMask.insert(.resizable)
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentMinSize = CallLayout.videoMinimum
            let frame = Self.frame(of: CallLayout.video, around: window.frame, on: window.screen)
            window.setFrame(frame, display: true)
            return
        }
        if wasVideo {
            window.styleMask.remove(.resizable)
            window.collectionBehavior = [.fullScreenNone]
            window.contentMinSize = .zero
        }
        guard let content else { return }
        let size = content.fittingSize
        guard size != window.frame.size else { return }
        let frame = wasVideo || isNewCall
            ? Self.frame(of: size, around: window.frame, on: window.screen)
            : NSRect(origin: NSPoint(x: window.frame.minX, y: window.frame.maxY - size.height), size: size)
        window.setFrame(frame, display: true)
    }

    /// A frame of `size` sharing `frame`'s center, kept on the screen.
    static func frame(of size: CGSize, around frame: NSRect, on screen: NSScreen?) -> NSRect {
        var next = NSRect(
            x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
        if let visible = screen?.visibleFrame {
            next.origin.x = min(max(next.minX, visible.minX), max(visible.minX, visible.maxX - next.width))
            next.origin.y = min(max(next.minY, visible.minY), max(visible.minY, visible.maxY - next.height))
        }
        return next
    }
}

/// Which stage the call window shows. Video is sticky for the call that first
/// showed it and resets with the next call.
struct CallWindowLayout: Equatable {
    private(set) var videoCall: UUID?

    var isVideo: Bool {
        videoCall != nil
    }

    func next(call: AudioCallSnapshot, hasVideo: Bool) -> Self {
        if videoCall == call.id {
            return self
        }
        return Self(videoCall: hasVideo && !call.phase.isTerminal ? call.id : nil)
    }
}

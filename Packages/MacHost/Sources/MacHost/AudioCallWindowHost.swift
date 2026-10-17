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
/// switched off for a moment does not make the window jump. When the person
/// has it on, the window closes itself a few seconds after a call ends.
@MainActor
public final class AudioCallWindowHost: NSObject, NSWindowDelegate {
    private let actionsForCall: (UUID) -> AudioCallActions
    private let windowClosed: (UUID) -> Void
    private let present: (NSWindow) -> Void
    private let incomingAttention: () -> Void
    private let now: () -> Date
    private let closesFinishedCalls: () -> Bool
    private let closeDelay: Duration
    private let pointerIsInside: (NSWindow) -> Bool
    private var closing: Task<Void, Never>?
    private var callID: UUID?
    private var lastWindowRequest: Int?
    private var isClosingSilently = false
    private(set) var timing = CallTiming()
    private(set) var layout = CallWindowLayout()
    private(set) var window: NSWindow?
    private var content: NSHostingView<AudioCallView>?

    public convenience init(
        actions: @escaping (UUID) -> AudioCallActions,
        windowClosed: @escaping (UUID) -> Void,
        closesFinishedCalls: @escaping () -> Bool = { false }
    ) {
        self.init(
            actions: actions,
            windowClosed: windowClosed,
            closesFinishedCalls: closesFinishedCalls,
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
        closesFinishedCalls: @escaping () -> Bool = { false },
        closeDelay: Duration = .seconds(3),
        pointerIsInside: @escaping (NSWindow) -> Bool = { $0.frame.contains(NSEvent.mouseLocation) },
        present: @escaping (NSWindow) -> Void,
        incomingAttention: @escaping () -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        actionsForCall = actions
        self.windowClosed = windowClosed
        self.closesFinishedCalls = closesFinishedCalls
        self.closeDelay = closeDelay
        self.pointerIsInside = pointerIsInside
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
            cancelClosing()
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
            cancelClosing()
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
        scheduleClose(after: call)
    }

    /// An ended or declined call's window closes after `closeDelay`, later if
    /// the pointer is over it, so a reach for Call Back is not cut off. A failed
    /// call, or one ending with a cleanup warning, stays open to be read.
    static func closesAutomatically(_ call: AudioCallSnapshot) -> Bool {
        (call.phase == .ended || call.phase == .declined) && call.failureMessage == nil
    }

    private func scheduleClose(after call: AudioCallSnapshot) {
        guard Self.closesAutomatically(call), closesFinishedCalls() else {
            cancelClosing()
            return
        }
        guard closing == nil else { return }
        let id = call.id, delay = closeDelay, pointerIsInside = pointerIsInside
        let poll = min(delay, .seconds(1))
        closing = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            while let window = self?.window, self?.callID == id, window.isVisible, pointerIsInside(window) {
                do { try await Task.sleep(for: poll) } catch { return }
            }
            guard let self, !Task.isCancelled, callID == id else { return }
            closing = nil
            window?.close()
        }
    }

    private func cancelClosing() {
        closing?.cancel()
        closing = nil
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
            screenSharing: video?.screenSharing.state,
            screenPreview: video.flatMap(CallVideoSurface.screen(for:))
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
        window.identifier = CallSurface.callWindow
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

/// Kibble's call windows, which a whole-display share leaves out.
@MainActor
enum CallSurface {
    static let callWindow = NSUserInterfaceItemIdentifier("KibbleCallWindow")
    static let incomingPanel = NSUserInterfaceItemIdentifier("KibbleIncomingCallPanel")

    static func contains(windowNumber: Int) -> Bool {
        guard let identifier = NSApp.window(withWindowNumber: windowNumber)?.identifier else { return false }
        return identifier == callWindow || identifier == incomingPanel
    }
}

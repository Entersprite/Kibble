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
/// switched off for a moment does not make the window jump. Either size can
/// go full screen; a change of layout while it is full screen resizes the
/// window when it leaves. When the person has it on, the window closes itself
/// a few seconds after a call ends.
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
    private let isFullScreen: (NSWindow) -> Bool
    private var closing: Task<Void, Never>?
    private var callID: UUID?
    private var lastWindowRequest: Int?
    private var isClosingSilently = false
    /// Between asking for full screen, or to leave it, and AppKit finishing.
    private var isChangingFullScreen = false
    /// What the window's frame was last sized for. Kept apart from `layout`,
    /// which can change while the window is full screen and not resized.
    private var isSizedForVideo = false
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
        isFullScreen: @escaping (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) },
        present: @escaping (NSWindow) -> Void,
        incomingAttention: @escaping () -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        actionsForCall = actions
        self.windowClosed = windowClosed
        self.closesFinishedCalls = closesFinishedCalls
        self.closeDelay = closeDelay
        self.pointerIsInside = pointerIsInside
        self.isFullScreen = isFullScreen
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
        call: AudioCallSession?,
        windowRequests: Int,
        devices: CallAudioDevices? = nil,
        alertsIncoming: Bool = true,
        video: CallVideoController? = nil,
        person: Member? = nil,
        conversation: Conversation? = nil,
        participants: [CallParticipantDevice]? = nil
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
        window.title = call.displayName
        render(call, in: window, devices: devices, video: video, people: CallPeople(
            person: person, conversation: conversation, participants: participants
        ))
        resize(window, isNewCall: isNewCall)
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
    static func closesAutomatically(_ call: AudioCallSession) -> Bool {
        (call.phase == .ended || call.phase == .declined) && call.failureMessage == nil
    }

    private func scheduleClose(after call: AudioCallSession) {
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
        _ call: AudioCallSession, in window: NSWindow, devices: CallAudioDevices?,
        video: CallVideoController?, people: CallPeople
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
            person: people.person,
            conversation: people.conversation,
            participants: people.participants,
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

    /// AppKit leaves a window that cannot be resized at its own size in the
    /// full-screen space, so the audio size is lent `.resizable` until
    /// `resize` takes it back on the way out.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
        window?.styleMask.insert(.resizable)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
        resize(window, isNewCall: false)
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
    }

    /// AppKit has put back the frame from before full screen, which is the
    /// wrong size if the call switched to video, or a new call began, meanwhile.
    public func windowDidExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        if let window {
            resize(window, isNewCall: false)
        }
    }

    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
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
        // Not resizable at the audio size, and full screen all the same: the
        // stage fills whatever window it is in.
        window.collectionBehavior = [.fullScreenPrimary]
        window.identifier = CallSurface.callWindow
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// The audio size follows the content, keeping the top edge where it was.
    /// The video size is set once, on the switch, and is the person's after that.
    /// Full screen owns the frame; leaving it calls this again.
    private func resize(_ window: NSWindow, isNewCall: Bool) {
        guard !isChangingFullScreen, !isFullScreen(window) else { return }
        let wasVideo = isSizedForVideo
        isSizedForVideo = layout.isVideo
        if layout.isVideo {
            guard !wasVideo else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = CallLayout.videoMinimum
            let frame = Self.frame(of: CallLayout.video, around: window.frame, on: window.screen)
            window.setFrame(frame, display: true)
            return
        }
        // Also after full screen, which lent it.
        window.styleMask.remove(.resizable)
        if wasVideo {
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

/// Who the window shows: the person called, or the conversation and the
/// devices its call reports.
struct CallPeople {
    var person: Member?
    var conversation: Conversation?
    var participants: [CallParticipantDevice]?
}

/// Which stage the call window shows. Video is sticky for the call that first
/// showed it and resets with the next call.
struct CallWindowLayout: Equatable {
    private(set) var videoCall: UUID?

    var isVideo: Bool {
        videoCall != nil
    }

    func next(call: AudioCallSession, hasVideo: Bool) -> Self {
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

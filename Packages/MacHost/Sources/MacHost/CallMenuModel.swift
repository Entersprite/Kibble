import AppCore
import ChatKit
import DesignSystem
import Foundation
import Observation

/// The menu bar's Call menu, kept current from the calls this process
/// presents.
///
/// The call window is AppKit's, so nothing it shows reaches the menu bar the
/// way the main window's state does; this reads the host's observed call
/// state instead. Each account has its own call controller, and a call on
/// any of them holds this Mac's microphone and camera, so the menu follows
/// the one call that holds the device, whichever account is selected. While
/// none does it shows the selected account's items, disabled.
///
/// The menu is a value, replaced only when it changes: the camera list
/// refreshes every two seconds during a call, and the menu bar should not be
/// rebuilt for that.
@MainActor
@Observable
public final class CallMenuModel {
    /// One account's calls and, where its calls carry video, its camera.
    struct Source {
        let calls: AudioCallController
        let video: CallVideoController?
    }

    /// `nil` while no account can place a call, which draws no Call menu.
    public private(set) var menu: CallMenu?
    @ObservationIgnored private var sources: (@MainActor () -> (all: [Source], selected: Source?))?

    init() {}

    /// Starts following the calls `sources` names, read again on every change.
    func start(sources: @escaping @MainActor () -> (all: [Source], selected: Source?)) {
        guard self.sources == nil else { return }
        self.sources = sources
        observe()
    }

    private func observe() {
        guard let sources else { return }
        let next = withObservationTracking {
            let current = sources()
            return Self.menu(all: current.all, selected: current.selected)
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
        if next != menu {
            menu = next
        }
    }

    /// The menu for the call holding the device, else for the selected
    /// account's calls, else for any account's that can place one.
    static func menu(all: [Source], selected: Source?) -> CallMenu? {
        let available = selected.flatMap { $0.calls.isAvailable ? $0 : nil } ?? all
            .first { $0.calls.isAvailable }
        guard let source = all.first(where: \.calls.holdsDevice) ?? available else { return nil }
        let video = source.video
        return CallMenu(
            call: source.calls.call, isEnding: source.calls.isEnding, camera: video?.camera,
            screenSharing: video?.screenSharing.state, offersVideo: video?.isAvailable == true
        )
    }

    public func toggleMute() {
        perform { source, _ in source.calls.toggleMute() }
    }

    public func toggleCamera() {
        perform { source, id in
            if MacAppDelegate.canUseVideo(in: id, calls: source.calls) {
                source.video?.toggle()
            }
        }
    }

    public func toggleScreenSharing() {
        perform { source, id in
            if MacAppDelegate.canUseVideo(in: id, calls: source.calls) {
                source.video?.screenSharing.toggle()
            }
        }
    }

    public func hangUp() {
        perform { source, _ in source.calls.hangUp() }
    }

    /// Acts on the call the menu showed, found again when chosen: never on a
    /// call that began on another account since the menu was drawn.
    private func perform(_ body: (Source, UUID) -> Void) {
        guard let id = menu?.callID,
              let source = sources?().all.first(where: { $0.calls.call?.id == id && $0.calls.holdsDevice })
        else { return }
        body(source, id)
    }
}

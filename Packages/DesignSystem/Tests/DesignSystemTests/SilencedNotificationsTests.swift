import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// When the "has notifications silenced" line shows above the composer, and
/// when it leaves.
struct SilencedNotificationsTests {
    private let me = Member.ID("me")
    private let ada = Member.ID("u-1")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func notice(
        _ presence: Presence?,
        until: Date? = nil,
        kind: Conversation.Kind = .directMessage,
        partnerKind: Member.Kind = .human,
        me known: Bool = true,
        connection: ConnectionState = .connected
    ) -> SilencedNotificationsNotice? {
        let directory = [
            ada: Member(
                id: ada, kind: partnerKind, displayName: "Ada", presence: presence, doNotDisturbUntil: until
            ),
            me: Member(id: me, kind: .human, displayName: "Me", presence: .doNotDisturb)
        ]
        return SilencedNotificationsNotice(
            conversation: Conversation(id: Conversation.ID("dm/1"), kind: kind, members: [me, ada]),
            directory: directory, me: known ? me : nil, connection: connection
        )
    }

    /// The other person's Do not disturb, never your own, which is on here
    /// so a lookup of the wrong member would show the line.
    @Test func aDirectMessageWithSomeoneInDoNotDisturbShowsIt() throws {
        let end = now.addingTimeInterval(3600)
        let shown = try #require(notice(.doNotDisturb, until: end))
        #expect(shown
            .text ==
            "Ada has notifications silenced until \(end.formatted(date: .omitted, time: .shortened))")
        #expect(notice(.doNotDisturb)?.text == "Ada has notifications silenced")
        #expect(shown.until == end)
        #expect(notice(.active) == nil)
        #expect(notice(.inactive) == nil)
    }

    @Test func nothingOutsideAOneToOneDirectMessage() {
        for kind: Conversation.Kind in [.groupDirectMessage, .appDirectMessage, .space, .meetChat] {
            #expect(notice(.doNotDisturb, kind: kind) == nil)
        }
    }

    /// An app has no notifications to silence.
    @Test func nothingForAnApp() {
        #expect(notice(.doNotDisturb, partnerKind: .app) == nil)
    }

    /// Presence's own rules: a claim about now, and about someone else.
    @Test func nothingOfflineOrBeforeTheLocalUserIsKnown() {
        #expect(notice(.doNotDisturb, connection: .disconnected(reason: nil, issue: nil)) == nil)
        #expect(notice(.doNotDisturb, me: false) == nil)
        #expect(notice(nil) == nil)
        #expect(notice(.unknown("absent")) == nil)
    }

    /// Shown until its end and not at it; with no end said, until presence
    /// changes.
    @Test func itLeavesWhenTheEndPasses() throws {
        let end = now.addingTimeInterval(60)
        let timed = try #require(notice(.doNotDisturb, until: end))
        #expect(timed.isShown(at: now))
        #expect(!timed.isShown(at: end))
        #expect(!timed.isShown(at: end.addingTimeInterval(1)))
        let open = try #require(notice(.doNotDisturb))
        #expect(open.isShown(at: now.addingTimeInterval(86400)))
    }

    /// An end already past when the window draws hides it at once.
    @Test func anEndAlreadyPastShowsNothing() throws {
        let stale = try #require(notice(.doNotDisturb, until: Date.now.addingTimeInterval(-5)))
        #expect(!stale.isShown(at: .now))
    }
}

#if os(macOS)
    import AppKit
    import SwiftUI

    /// The line as drawn: its height while shown and none once it has ended,
    /// so the composer's stack does not keep a gap, and its looks in both
    /// appearances when `KIBBLE_RENDER_CAPTURE_DIR` names a folder.
    @MainActor
    struct SilencedNotificationsLineTests {
        private func notice(until: Date?) throws -> SilencedNotificationsNotice {
            let me = Member.ID("me")
            let ada = Member.ID("u-1")
            return try #require(SilencedNotificationsNotice(
                conversation: Conversation(id: .init("dm/1"), kind: .directMessage, members: [me, ada]),
                directory: [ada: Member(
                    id: ada, kind: .human, displayName: "Rita Example", presence: .doNotDisturb,
                    doNotDisturbUntil: until
                )],
                me: me, connection: .connected
            ))
        }

        private func height(of notice: SilencedNotificationsNotice) -> CGFloat {
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                SilencedNotificationsLine(notice: notice)
            }.frame(width: 480))
            return host.fittingSize.height
        }

        @Test func anEndedLineTakesNoHeight() throws {
            #expect(try height(of: notice(until: Date.now.addingTimeInterval(3600))) > 10)
            #expect(try height(of: notice(until: nil)) > 10)
            #expect(try height(of: notice(until: Date.now.addingTimeInterval(-1))) == 0)
        }

        @Test func theSymbolExists() {
            #expect(NSImage(
                systemSymbolName: SilencedNotificationsLine.symbol,
                accessibilityDescription: nil
            ) != nil)
        }

        /// The line's own timeline takes it away at the end, with nothing
        /// else redrawing: shown, then no height once the end has passed.
        @Test func theLineLeavesAtItsEnd() async throws {
            let ending = try notice(until: Date.now.addingTimeInterval(0.4))
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                SilencedNotificationsLine(notice: ending)
            }.frame(width: 480))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 60), styleMask: [], backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 10)
            for _ in 0 ..< 60 where host.fittingSize.height > 0 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
            }
            #expect(host.fittingSize.height == 0)
        }

        @Test func theLineRendersInBothAppearances() throws {
            guard let path = ProcessInfo.processInfo.environment["KIBBLE_RENDER_CAPTURE_DIR"] else { return }
            let notice = try notice(until: Date.now.addingTimeInterval(3600))
            for dark in [false, true] {
                let view = VStack(spacing: 0) {
                    SilencedNotificationsLine(notice: notice)
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.separator)
                        .frame(height: 36)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .frame(width: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path)
                    .appendingPathComponent("silenced-\(dark ? "dark" : "light").png"))
            }
        }
    }
#endif

#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// A wrong SF Symbol name compiles and draws nothing (`CLAUDE.md`). Every
    /// symbol the menu bar's own items show is checked on this system, and,
    /// since the app still runs on macOS 26, against the release that
    /// introduced it.
    @MainActor
    struct MenuBarSymbolsTests {
        private var conversationSymbols: [String] {
            let recorder = MenuActionRecorder()
            let space = Conversation(id: .init("space"), kind: .space, repliesEnabled: true)
            let muted = ChatSceneState(conversations: [space], selected: space.id, muted: [space.id])
            let menus = [
                ConversationMenuBar(state: nil, actions: recorder.actions),
                ConversationMenuBar(state: muted, actions: recorder.actions)
            ]
            return menus.flatMap { $0.sections.joined() }.compactMap { entry in
                if case let .button(symbol) = entry.style {
                    return symbol
                }
                return nil
            }
        }

        private var callSymbols: [String] {
            var on = CallCameraState()
            on.isOn = true
            let call = AudioCallSnapshot(
                id: UUID(), recipient: AudioCallRecipient(
                    conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
                ), direction: .outgoing, phase: .connected, isMuted: true
            )
            let menus = [
                CallMenu(call: nil, isEnding: false, camera: nil, screenSharing: nil, offersVideo: true),
                CallMenu(
                    call: call, isEnding: false, camera: on,
                    screenSharing: CallScreenShareState(phase: .sharing),
                    offersVideo: true
                )
            ]
            return menus.flatMap(\.entries).map(\.symbol)
        }

        @Test func everySymbolExists() {
            let names = MenuBarSymbols.all + conversationSymbols + callSymbols
            #expect(Set(conversationSymbols).count == 12)
            #expect(Set(callSymbols).count == 7)
            for name in names {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }

        /// Introduced no later than macOS 26, which the app still supports,
        /// read from the symbol catalog's availability table.
        @Test func everySymbolIsAvailableOnTheOldestSupportedSystem() throws {
            let url = URL(fileURLWithPath:
                "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
            let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
            let symbols = try #require(plist["symbols"] as? [String: String])
            let releases = try #require(plist["year_to_release"] as? [String: [String: String]])
            for name in Set(MenuBarSymbols.all + conversationSymbols + callSymbols) {
                let macOS = symbols[name].flatMap { releases[$0]?["macOS"] }
                let major = macOS.flatMap { Double($0) } ?? .infinity
                #expect(major <= 26, "\(name) needs macOS \(macOS ?? "?")")
            }
        }
    }
#endif

#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Sidebar symbols stay visible while the window is in front, are all one
    /// size, and leave every row's name starting at the same place.
    @MainActor
    @Suite(.serialized)
    struct SidebarSymbolRenderTests {
        private static let size = NSSize(width: 240, height: 140)

        private func render(
            _ view: some View, size: NSSize = Self.size, dark: Bool = true
        ) async throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: view
                .listStyle(.sidebar)
                .environment(\.controlActiveState, .key)
                .frame(width: size.width, height: size.height, alignment: .topLeading))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = host.appearance
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        /// The brightest pixel in the icon column, where only the symbols are
        /// drawn (the names start further right).
        private func brightestIcon(in rep: NSBitmapImageRep) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / Self.size.width
            var brightest: CGFloat = 0
            for column in Int(14 * scale) ..< Int(34 * scale) {
                for row in 0 ..< rep.pixelsHigh {
                    guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    brightest = max(brightest, color.brightnessComponent * color.alphaComponent)
                }
            }
            return brightest
        }

        /// Points, from the leading edge, of the first column at or after
        /// `from` holding anything darker than the white background.
        private func firstInk(in rep: NSBitmapImageRep, width: CGFloat, from: CGFloat = 0) -> CGFloat? {
            let scale = CGFloat(rep.pixelsWide) / width
            for column in Int(from * scale) ..< rep.pixelsWide {
                for row in 0 ..< rep.pixelsHigh {
                    guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    if color.alphaComponent > 0.1, color.brightnessComponent < 0.8 {
                        return CGFloat(column) / scale
                    }
                }
            }
            return nil
        }

        /// The drawn extent, in points, of whatever is darker than the white
        /// background.
        private func inkSize(in rep: NSBitmapImageRep, width: CGFloat) -> CGSize {
            let scale = CGFloat(rep.pixelsWide) / width
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for column in 0 ..< rep.pixelsWide {
                for row in 0 ..< rep.pixelsHigh {
                    guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.1, color.brightnessComponent < 0.8 else { continue }
                    minX = min(minX, column)
                    maxX = max(maxX, column)
                    minY = min(minY, row)
                    maxY = max(maxY, row)
                }
            }
            guard minX <= maxX else { return .zero }
            return CGSize(
                width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
            )
        }

        private func onWhite(_ view: some View) -> some View {
            view.padding(4).background(Color.white)
        }

        @Test func pinnedRowAndSpaceSymbolsStayGrayInAFocusedDarkWindow() async throws {
            let space = Conversation(id: .init("space/1"), kind: .space, title: "Design")
            let rep = try await render(List {
                MentionsSidebarRow(unread: 0)
                ThreadsSidebarRow(unread: 0)
                ConversationRow(
                    conversation: space,
                    state: ConversationRowState(
                        conversation: space, scene: ChatSceneState(conversations: [space])
                    )
                )
            })
            // A gray symbol on the dark sidebar is far brighter than the
            // sidebar itself; a black one is not.
            #expect(brightestIcon(in: rep) > 0.4)
        }

        /// Threads' two bubbles are no larger than Search's magnifier: every
        /// symbol is fitted into one square, the size of the row's text. Drawn
        /// at the row's font instead, as a sidebar `Label` draws its icon, the
        /// Threads symbol came out about half as wide again as the others.
        @Test func everySidebarSymbolIsDrawnAtOneSize() async throws {
            let names = [
                SidebarPinned.searchSymbol, SidebarPinned.mentionsSymbol, ThreadsPresentation.rowSymbol,
                SidebarRowPicture.seeAllSymbol
            ]
            let side = SidebarRowPicture.symbol(.medium)
            let canvas = NSSize(width: 40, height: 40)
            var largest: [String: CGFloat] = [:]
            for name in names {
                let rep = try await render(onWhite(SidebarSymbol(name: name)), size: canvas, dark: false)
                let ink = inkSize(in: rep, width: canvas.width)
                largest[name] = max(ink.width, ink.height)
            }
            for name in names {
                let extent = try #require(largest[name])
                #expect(extent <= side + 0.5, "\(name) is \(extent) pt")
                #expect(extent >= side - 2, "\(name) is \(extent) pt")
            }
        }

        /// A pinned row's name starts where a conversation's does, so the
        /// sidebar's names form one column.
        @Test func pinnedAndConversationNamesStartTogether() async throws {
            let width: CGFloat = 200
            let space = Conversation(id: .init("space/1"), kind: .space, title: "Design")
            let dm = Conversation(
                id: .init("dm/1"), kind: .directMessage, title: "Design", members: [.init("a")]
            )
            let scene = ChatSceneState(conversations: [space, dm])
            let rows: [AnyView] = [
                AnyView(SidebarSymbolTitle(title: "Design", symbol: SidebarPinned.mentionsSymbol)),
                AnyView(SidebarSymbolTitle(title: "Design", symbol: ThreadsPresentation.rowSymbol)),
                AnyView(ConversationRow(
                    conversation: space, state: ConversationRowState(conversation: space, scene: scene)
                )),
                AnyView(ConversationRow(
                    conversation: dm, state: ConversationRowState(conversation: dm, scene: scene)
                ))
            ]
            var starts: [CGFloat] = []
            for row in rows {
                let rep = try await render(
                    row.frame(width: width, alignment: .leading).background(Color.white),
                    size: NSSize(width: width, height: 30), dark: false
                )
                // Past the picture column, where only the name is drawn.
                let column = SidebarRowPicture.diameter(.medium) + 2
                try starts.append(#require(firstInk(in: rep, width: width, from: column)))
            }
            let first = try #require(starts.first)
            #expect(starts.allSatisfy { abs($0 - first) < 0.6 }, "\(starts)")
        }
    }
#endif

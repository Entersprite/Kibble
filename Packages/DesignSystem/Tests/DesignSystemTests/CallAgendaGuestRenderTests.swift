#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct CallAgendaGuestRenderTests {
        @Test(arguments: [ColorScheme.light, .dark])
        func peopleWithoutJoinedGuestsCanShowCalendarInvitations(_ scheme: ColorScheme) throws {
            var state = CallActivitiesState()
            state.agendaGuests = [
                .init(
                    id: UUID(),
                    displayName: "Alex",
                    response: "accepted",
                    chatAddress: "alex@example.test"
                ),
                .init(id: UUID(), displayName: "Taylor", response: "tentative", isOptional: true)
            ]
            var scene = CallActivitiesScene(state: state, perform: { _ in })
            scene.openGuestChat = { _ in }
            let view = CallPeopleList(entries: [], activities: scene)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 215)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            #expect(image.size == host.bounds.size)
        }
    }
#endif

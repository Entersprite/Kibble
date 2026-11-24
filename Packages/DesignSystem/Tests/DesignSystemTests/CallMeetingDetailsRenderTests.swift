#if os(macOS)
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct CallMeetingDetailsRenderTests {
        @Test func waitingRoomDetailsAreReachableFromMoreWithNoConnectedControls() throws {
            let url = try #require(URL(string: "https://meet.example.test/fixture"))
            var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
            actions.meetingDetails = CallMeetingDetails(id: UUID(), url: url, dialIn: nil, copy: { _ in })
            let menu = CallMoreMenu(audio: nil, video: nil, diagnostics: nil, interactions: actions)
            #expect(menu.hasContent)
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func meetingDetailsFitsTheCompactCallWindow(_ scheme: ColorScheme) throws {
            let details = try CallMeetingDetails(
                id: UUID(),
                url: #require(URL(string: "https://meet.example.test/fixture")),
                dialIn: CallDialIn(phoneNumber: "+1 (202) 555-0142", pin: "012345678"),
                copy: { _ in }
            )
            let renderer = ImageRenderer(content: CallMeetingDetailsContent(details: details)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            #expect((175 ... Int(CallLayout.compact.width)).contains(image.width))
            #expect((100 ... Int(CallLayout.compact.height)).contains(image.height))
        }

        @Test(arguments: [ColorScheme.light, .dark], [true, false])
        func phoneDirectoryFitsWithOrWithoutAnInlinePicker(
            _ scheme: ColorScheme,
            _ showsPicker: Bool
        ) throws {
            let details = try CallMeetingDetails(
                id: UUID(), url: #require(URL(string: "https://meet.example.test/fixture")),
                dialIn: showsPicker ? CallDialIn(phoneNumber: "+1 (202) 555-0142", pin: "012345678") : nil,
                alternateDialIns: showsPicker
                    ? [CallDialIn(phoneNumber: "+44 20 7946 0958", pin: "987654321", regionCode: "GB")] : [],
                copy: { _ in }, openPhoneNumbers: {}
            )
            let renderer = ImageRenderer(content: CallMeetingDetailsContent(details: details)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            #expect((175 ... 352).contains(image.width))
            #expect((92 ... 235).contains(image.height))
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func attachmentOnlyDetailsKeepTheListInABoundedPopover(_ scheme: ColorScheme) throws {
            let files = try (0 ..< 20).map { row in
                let url = try #require(URL(string: "https://files.example.test/agenda/\(row)"))
                return CallAgendaAttachment(title: String(repeating: "Planning Agenda ", count: 15), url: url)
            }
            let details = try CallMeetingDetails(
                id: UUID(), url: #require(URL(string: "https://meet.example.test/fixture")),
                dialIn: nil, attachments: files, copy: { _ in }
            )
            let renderer = ImageRenderer(content: CallMeetingDetailsContent(details: details)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            #expect((200 ... 352).contains(image.width))
            #expect((144 ... 320).contains(image.height))
        }
    }
#endif

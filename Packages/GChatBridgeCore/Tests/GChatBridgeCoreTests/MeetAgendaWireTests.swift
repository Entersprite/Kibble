import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetAgendaWireTests {
    @Test func onlyReadyArtifactFilesBecomeLinks() {
        let recording = "https://drive.google.com/file/d/fixture-recording/view"
        let transcript = "https://docs.google.com/document/d/fixture-transcript/edit"
        let event = attachment(recording, kind: 3) + attachment(recording, kind: 3)
            + attachment(transcript, kind: 4) + attachment(
                "https://drive.google.com/open?id=pending",
                kind: 2,
                state: 2
            )
            + attachment("https://drive.google.com/open?id=attached", kind: 1)
        let files = MeetAgendaWire.artifacts(event)
        #expect(files.map(\.url.absoluteString) == [recording, transcript])
        #expect(files.map(\.kind) == [.recording, .transcription])
    }

    @Test(arguments: [
        "https://drive.google.com.evil.test/file/d/id/view",
        "https://name@docs.google.com/document/d/id/edit",
        "https://drive.google.com/file/d/id/../../open",
        "http://docs.google.com/document/d/id/edit",
        "https://docs.google.com/url?q=https://example.test",
        "https://drive.google.com/file/d//view"
    ])
    func unsafeOrUnrecognizedLinksAreOmitted(_ url: String) {
        #expect(MeetAgendaWire.artifacts(attachment(url, kind: 3)).isEmpty)
    }

    @Test func aForeignConferenceOrAbsentAgendaCannotPublishFiles() throws {
        let current = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let other = MeetProto.string(17, "https://meet.google.com/aaa-bbbb-ccc")
        let file = attachment("https://drive.google.com/open?id=recording", kind: 3)
        #expect(try MeetAgendaWire.event(envelope(other + file), matching: current) == nil)
        #expect(try MeetAgendaWire.event(Data(), matching: current) == nil)
        let returned = try MeetAgendaWire.event(
            envelope(MeetProto.string(17, current.absoluteString) + file), matching: current
        )
        let matched = try #require(returned)
        #expect(MeetAgendaWire.artifacts(matched).count == 1)
    }

    @Test func calendarAttachmentsIncludeReadyAndUnspecifiedStatesWithoutRepeatingArtifacts() {
        let spreadsheet = "https://docs.google.com/spreadsheets/d/fixture-sheet/edit#gid=0"
        let presentation = "https://docs.google.com/presentation/d/fixture-deck/edit"
        let file = "https://drive.google.com/file/d/fixture-file/view?resourcekey=fixture-key"
        let event = attachment(spreadsheet, kind: 1, state: 0, title: "Agenda")
            + attachment(presentation, kind: 1, state: nil)
            + attachment(file, kind: 1)
            + attachment(file, kind: 1, title: "Duplicate")
            + attachment("https://drive.google.com/open?id=pending", kind: 1, state: 2)
            + attachment("https://drive.google.com/open?id=recording", kind: 3)
            + attachment("https://drive.google.com/open?id=unknown", kind: 0)
        let rows = MeetAgendaWire.attachments(event)
        #expect(rows.map(\.url.absoluteString) == [spreadsheet, presentation, file])
        #expect(rows.map(\.title) == ["Agenda", nil, nil])
        #expect(MeetAgendaWire.artifacts(event).map(\.kind) == [.recording])
    }

    @Test func ordinaryAttachmentsRejectUnknownTargetsAndMalformedState() {
        let path = "https://docs.google.com/spreadsheets/d/fixture-sheet/edit"
        let wrongType = MeetProto.string(1, path) + MeetProto.number(6, 1) + MeetProto.string(7, "")
        let duplicate = MeetProto.string(1, path) + MeetProto.number(6, 1)
            + MeetProto.number(7, 1) + MeetProto.number(7, 0)
        let event = MeetProto.bytes(19, wrongType) + MeetProto.bytes(19, duplicate)
            + attachment("https://docs.google.com/forms/d/e/example/formResponse", kind: 1)
            + attachment("https://other.example.test/agenda", kind: 1)
        #expect(MeetAgendaWire.attachments(event).isEmpty)
    }

    @Test func calendarGuestsRespectVisibilityAndKeepRSVPSeparateFromPresence() {
        let declined = guest(email: "Taylor@example.test", name: "Taylor", response: 2)
        let tentative = guest(email: "Alex@example.test", name: "Alex", response: 3, flag: 4)
        let accepted = guest(email: "Morgan@example.test", name: "Morgan", response: 4)
        let selfRow = guest(email: "host@example.test", name: "Host", response: 4, flag: 7)
        let other = guest(email: "room@example.test", name: "Room", response: 4, flag: 3)
        let event = declined + tentative + selfRow + accepted + other + accepted
        let guests = MeetAgendaGuestWire.guests(event)
        #expect(guests.map(\.displayName) == ["Morgan", "Alex", "Taylor"])
        #expect(guests.map(\.response) == [.accepted, .tentative, .declined])
        #expect(guests.map(\.isOptional) == [false, true, false])
        #expect(guests.map(\.alias) == ["morgan@example.test", "alex@example.test", "taylor@example.test"])
        #expect(guests.map(\.chatAddress) == guests.map(\.alias))
        #expect(MeetAgendaGuestWire.guests(event + MeetProto.number(29, 3)).allSatisfy {
            $0.chatAddress != nil
        })
        for reason: UInt64 in [2, 5, 6] {
            let denied = MeetAgendaGuestWire.guests(event + MeetProto.number(29, reason))
            #expect(denied.count == guests.count && denied.allSatisfy { $0.chatAddress == nil })
        }
        #expect(MeetAgendaGuestWire.guests(event + MeetProto.number(28, 1)).isEmpty)
        #expect(MeetAgendaGuestWire.guests(event + MeetProto.number(29, 4)).isEmpty)
        #expect(MeetAgendaGuestWire.guests(event + MeetProto.string(29, "invalid")).isEmpty)
        let aliases = MeetProto.string(43, "Alex@EXAMPLE.TEST") + MeetProto.string(43, "123456")
        #expect(MeetAgendaGuestWire.aliases(aliases) == ["alex@example.test"])
    }

    private func guest(email: String, name: String, response: UInt64, flag: UInt64? = nil) -> Data {
        let row = MeetProto.string(1, email) + MeetProto.string(2, name) + MeetProto.number(5, response)
            + (flag.map { MeetProto.number($0, 1) } ?? Data())
        return MeetProto.bytes(14, row)
    }

    private func attachment(_ url: String, kind: UInt64, state: UInt64? = 1, title: String? = nil) -> Data {
        let file = MeetProto.string(1, url) + MeetProto.number(6, kind)
            + (state.map { MeetProto.number(7, $0) } ?? Data())
            + (title.map { MeetProto.string(2, $0) } ?? Data())
        return MeetProto.bytes(19, file)
    }

    private func envelope(_ event: Data) -> Data {
        Data(MeetProto.bytes(1, event).base64EncodedString().utf8)
    }
}

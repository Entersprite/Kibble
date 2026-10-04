import Foundation
import Testing
@testable import ChatKit

/// The direction of the default is the whole design. An older client talking to
/// a newer backend must assume *less* capability than exists: a greyed-out
/// button disappoints, a button that silently drops the user's message loses
/// data.
@Suite("Capabilities")
struct CapabilitiesTests {
    @Test("an empty object decodes with every flag false")
    func emptyObjectIsAllFalse() throws {
        let capabilities = try Wire.decode(Capabilities.self, from: "{}")
        #expect(capabilities == Capabilities())
        #expect(capabilities.canSendMessages == false)
        #expect(capabilities.canEditMessages == false)
        #expect(capabilities.canDeleteMessages == false)
        #expect(capabilities.canReact == false)
        #expect(capabilities.canSendTypingState == false)
        #expect(capabilities.receivesTypingState == false)
        #expect(capabilities.receivesReadReceipts == false)
        #expect(capabilities.canSetNotificationLevel == false)
        #expect(capabilities.canMarkRead == false)
        #expect(capabilities.supportsThreads == false)
        #expect(capabilities.supportsHistoryCatchUp == false)
        #expect(capabilities.canFetchAttachments == false)
        #expect(capabilities.canDownloadFiles == false)
        #expect(capabilities.canFetchCustomEmoji == false)
        #expect(capabilities.extendedFlags.isEmpty)
    }

    /// The failure this guards against is a decoder written with `?? true`, or
    /// an `Optional<Bool>` treated as "unset means yes".
    @Test("a partial object leaves the unmentioned flags false, never true")
    func partialObjectDoesNotInvent() throws {
        let json = #"{"canSendMessages":true,"supportsThreads":true}"#
        let capabilities = try Wire.decode(Capabilities.self, from: json)
        #expect(capabilities.canSendMessages)
        #expect(capabilities.supportsThreads)
        #expect(capabilities.canDeleteMessages == false)
        #expect(capabilities.canSetNotificationLevel == false)
        #expect(capabilities.supportsHistoryCatchUp == false)
        #expect(capabilities.canFetchAttachments == false)
        #expect(capabilities.canDownloadFiles == false)
    }

    @Test("the default initialiser is all-false too, so the two paths agree")
    func defaultInitialiserMatchesEmptyObject() throws {
        try expectWireStable(Capabilities(), golden: "capabilities-empty")
    }

    @Test("a populated capability set matches its golden file")
    func populated() throws {
        try expectWireStable(Fixture.capabilities, golden: "capabilities")
    }

    /// The escape hatch: a newer backend advertising something this build has no
    /// property for must not lose it, and must not need a schema bump to say it.
    @Test("extended flags survive and are encoded in sorted order")
    func extendedFlagsAreSortedAndPreserved() throws {
        let json = try Wire.json(Fixture.capabilities)
        #expect(json.contains(#""extendedFlags":["customEmoji","voiceRooms"]"#))

        let decoded = try Wire.decode(Capabilities.self, from: json)
        #expect(decoded.extendedFlags == ["voiceRooms", "customEmoji"])
    }

    @Test("an unrecognised capability key is ignored rather than fatal")
    func unknownKeyIsIgnored() throws {
        let json = #"{"canReact":true,"canTeleport":true}"#
        let capabilities = try Wire.decode(Capabilities.self, from: json)
        #expect(capabilities.canReact)
    }
}

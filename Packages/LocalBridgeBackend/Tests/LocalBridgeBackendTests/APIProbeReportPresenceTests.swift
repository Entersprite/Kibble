import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's `presence summary` section. Pinned because it settles the
/// presence poll's `[Verify]`s, and a probe line that misreports reads as a
/// verdict (`findings.md` §12.2).
struct APIProbeReportPresenceTests {
    private func entry(_ id: String, _ build: (inout UserPresence) -> Void = { _ in }) -> UserPresence {
        var entry = UserPresence()
        entry.userID.id = id
        build(&entry)
        return entry
    }

    private func lines(_ entries: [UserPresence], asked: [String]) -> [String] {
        var response = GetUserPresenceResponse()
        response.userPresences = entries
        return APIProbeReport.presenceLines(response, asked: asked.map { ChatKit.Member.ID($0) })
    }

    @Test func countsWhatWasAnsweredAgainstWhatWasAsked() {
        let report = lines([entry("u-1"), entry("stranger")], asked: ["u-1", "u-2"])
        #expect(report.first == "  entries returned: 2, of them asked about: 1")
    }

    @Test func splitsTheTwoDndFieldsAndReadsRawPresence() throws {
        var userID = UserId()
        userID.id = "u-3"
        var bytes = Data([0x0A])
        let idBytes: Data = try userID.serializedBytes()
        bytes.append(UInt8(idBytes.count))
        bytes.append(idBytes)
        bytes.append(contentsOf: [0x10, 0x09])
        let outside = try UserPresence(serializedBytes: bytes)

        let report = lines([
            entry("u-1") { $0.presence = .active; $0.dndState = .dnd },
            entry("u-2") { $0.presence = .inactive; $0.userStatus.dndSettings.dndState = .available },
            outside
        ], asked: ["u-1", "u-2", "u-3"])

        #expect(report.contains("  presence, typed or raw [active: 1, inactive: 1, raw=9: 1]"))
        #expect(report.contains("  dnd_state (field 3) [-: 2, dnd: 1]"))
        #expect(report.contains("  user_status.dnd_settings.dnd_state [-: 2, available: 1]"))
        #expect(report.contains("  mapped [doNotDisturb: 1, inactive: 1, unknown(\"presence=9\"): 1]"))
    }

    /// A custom status is counted, and its text never printed.
    @Test func neverPrintsACustomStatus() {
        let report = lines(
            [entry("u-1") { $0.userStatus.customStatus.statusText = "on holiday" }],
            asked: ["u-1"]
        )
        #expect(report.contains { $0.contains("with custom status: 1") })
        #expect(!report.joined().contains("holiday"))
    }
}

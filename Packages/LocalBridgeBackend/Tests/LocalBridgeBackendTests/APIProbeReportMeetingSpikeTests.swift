import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

/// The in-a-meeting spike's probe lines. Pinned because a shape that
/// misreports reads as an answer (`findings.md` §12.2), and because these
/// lines sit beside real status text that must never be printed.
struct APIProbeReportMeetingSpikeTests {
    /// A `UserStatus` for `id` carrying `unnamed` after its known fields:
    /// field 9 = 2 (an ordinal), 10 = a nested message {1 = 1}, 11 = 300 (not
    /// an ordinal), and 12 = the text "In a meeting".
    private func status(_ id: String, unnamed: Bool = true) throws -> UserStatus {
        var known = UserStatus()
        known.userID.id = id
        var bytes: Data = try known.serializedBytes()
        if unnamed {
            bytes.append(contentsOf: [0x48, 0x02])
            bytes.append(contentsOf: [0x52, 0x02, 0x08, 0x01])
            bytes.append(contentsOf: [0x58, 0xAC, 0x02])
            let text = Data("In a meeting".utf8)
            bytes.append(contentsOf: [0x62, UInt8(text.count)])
            bytes.append(text)
        }
        return try UserStatus(serializedBytes: bytes)
    }

    @Test func aShapeNamesNumbersOrdinalsAndNestingButNeverText() throws {
        let shape = try APIProbeReport.unnamedShape(of: status("u-1"))
        #expect(shape == "9=2,10{1=1},11:varint,12:bytes")
        #expect(!shape.contains("meeting"))
    }

    /// Known fields are the proto's business, not the spike's.
    @Test func knownFieldsAreNotReported() throws {
        #expect(try APIProbeReport.unnamedShape(of: status("u-1", unnamed: false)) == "-")
    }

    @Test func theLocalUsersEntryIsReportedApart() throws {
        var mine = UserPresence()
        mine.userID.id = "me"
        mine.presence = .active
        mine.userStatus = try status("me")
        var theirs = UserPresence()
        theirs.userID.id = "u-2"
        var response = GetUserPresenceResponse()
        response.userPresences = [mine, theirs]

        let lines = APIProbeReport.unnamedPresenceLines(response, selfUserID: "me")

        #expect(lines.contains("  unnamed fields, its user_status [-: 1, 9=2,10{1=1},11:varint,12:bytes: 1]"))
        #expect(lines.contains {
            $0.hasPrefix("  self: presence active,") && $0
                .hasSuffix("user_status 9=2,10{1=1},11:varint,12:bytes")
        })
        #expect(!lines.joined().contains("me,") && !lines.joined().contains("u-2"))
    }

    @Test func anAnswerWithoutTheLocalUserSaysSo() throws {
        var response = GetUserStatusResponse()
        response.userStatuses = try [status("u-1")]
        let lines = APIProbeReport.userStatusLines(response, selfUserID: "me")
        #expect(lines.contains("  self: not in the answer"))
        #expect(lines.contains("  unnamed fields, UserStatus [9=2,10{1=1},11:varint,12:bytes: 1]"))
    }

    @Test func theSelfStatusNeverPrintsItsCustomText() throws {
        var response = GetSelfUserStatusResponse()
        response.userStatus = try status("me")
        response.userStatus.customStatus.statusText = "On holiday"
        let lines = APIProbeReport.selfStatusLines(response)
        #expect(lines.first == "  dnd -, custom status present")
        #expect(!lines.joined().contains("holiday"))
        #expect(!lines.joined().contains("meeting"))
    }
}

import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

@Suite("Sanitized diagnostic stacks")
struct DiagnosticReportStoreTests {
    @Test func keepsSymbolicationFieldsButDropsPathsAndAddresses() throws {
        let uuid = "70B89F27-1634-3580-A695-57CDB41D7743"
        let raw: [String: Any] = [
            "callStackTree": [
                "callStacks": [[
                    "threadAttributed": true,
                    "callStackRootFrames": [[
                        "binaryUUID": uuid,
                        "offsetIntoBinaryTextSegment": 165_304,
                        "address": 7_170_766_264 as Int64,
                        "binaryName": "/Users/alice/private/Kibble.app",
                        "subFrames": [["binaryUUID": "invalid", "offsetIntoBinaryTextSegment": 1]]
                    ]]
                ]]
            ]
        ]
        let stacks = try SanitizedStack.from(JSONSerialization.data(withJSONObject: raw))
        #expect(stacks.count == 1)
        #expect(stacks[0].attributed)
        #expect(stacks[0].frames.count == 1)
        #expect(stacks[0].frames[0].binaryUUID == uuid)
        #expect(stacks[0].frames[0].offset == 165_304)
        let exported = try String(decoding: JSONEncoder().encode(stacks), as: UTF8.self)
        #expect(!exported.contains("alice"))
        #expect(!exported.contains("7170766264"))
        #expect(!exported.contains("Kibble.app"))
    }
}

extension DiagnosticReportStoreTests {
    @Test func conversationRequestDiagnosticsSurviveRelaunchAndStayBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticReportStore(directory: directory)
        for _ in 0 ..< 55 {
            store.recordConversationAction(ConversationActionObservation(
                rpc: "NyBsFc", status: 200, serviceCode: 3, outcome: "serviceFailure"
            ))
        }
        let reopened = DiagnosticReportStore(directory: directory)
        let data = try reopened.exportData()
        let export = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(export["schemaVersion"] as? Int == 2)
        let actions = try #require(export["conversationActions"] as? [[String: Any]])
        #expect(actions.count == 50)
        let request = try #require(actions.last?["request"] as? [String: Any])
        #expect(Set(request.keys) == ["rpc", "status", "serviceCode", "outcome"])
        #expect(request["serviceCode"] as? Int == 3)
    }
}

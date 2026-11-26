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
        #expect(export["schemaVersion"] as? Int == 3)
        let actions = try #require(export["conversationActions"] as? [[String: Any]])
        #expect(actions.count == 50)
        let request = try #require(actions.last?["request"] as? [String: Any])
        #expect(Set(request.keys) == ["rpc", "status", "serviceCode", "outcome"])
        #expect(request["serviceCode"] as? Int == 3)
    }
}

extension DiagnosticReportStoreTests {
    @Test func managementRequestsAndRedactedRefusalsSurviveRelaunchInTheSharedExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observation = try JSONDecoder().decode(ConversationActionObservation.self, from: Data(#"""
        {"rpc":"update_group","status":400,"serviceCode":3,"outcome":"httpRefusal",
         "management":{"stage":"settingsRequest",
          "request":{"updateMasks":[6],"policies":[],"defaultAudienceCount":1,
                     "canChangeAccess":true,"canChangeRequestToJoin":true},
          "refusal":{"bodyBytes":120,"format":"json","code":3,
                     "message":"Invalid space_permissions [redacted]"}}}
        """#.utf8))
        let store = DiagnosticReportStore(directory: directory)
        store.recordConversationAction(observation)
        let reopened = DiagnosticReportStore(directory: directory)
        let export = try #require(JSONSerialization.jsonObject(with: reopened.exportData()) as? [String: Any])
        let application = try #require(export["application"] as? [String: Any])
        #expect(application["managementRequestDiagnostics"] as? Bool == true)
        let actions = try #require(export["conversationActions"] as? [[String: Any]])
        let request = try #require(actions.first?["request"] as? [String: Any])
        let management = try #require(request["management"] as? [String: Any])
        #expect(management["stage"] as? String == "settingsRequest")
        let refusal = try #require(management["refusal"] as? [String: Any])
        #expect(refusal["code"] as? Int == 3)
        #expect(refusal["message"] as? String == "Invalid space_permissions [redacted]")
        reopened.clearAndSuspend()
        reopened.recordConversationAction(observation)
        let cleared = try #require(JSONSerialization
            .jsonObject(with: reopened.exportData()) as? [String: Any])
        #expect((cleared["conversationActions"] as? [Any])?.isEmpty == true)
    }
}

extension DiagnosticReportStoreTests {
    @Test func exportingSavesAndCopiesExactlyTheSameReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.json")
        let store = DiagnosticReportStore(directory: nil)
        var copied: String?
        try store.exportReport(to: url) { copied = $0 }
        let text = try #require(copied)
        #expect(try Data(contentsOf: url) == Data(text.utf8))
        let report = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let app = try #require(report["application"] as? [String: Any])
        #expect(app["managementDiagnosticsVersion"] as? Int == 6)
        copied = nil
        #expect(throws: (any Error).self) {
            try store
                .exportReport(to: directory.appendingPathComponent("missing/report.json")) { copied = $0 }
        }
        #expect(copied == nil)
    }
}

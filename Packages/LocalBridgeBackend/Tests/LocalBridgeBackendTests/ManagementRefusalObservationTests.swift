import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ManagementRefusalObservationTests {
    @Test func shortPlainTextRefusalsStillHaveARedactedReason() {
        let observation = ManagementRefusalObservation(
            Data("Invalid request data".utf8), sensitive: []
        )
        #expect(observation.bodyBytes == 20)
        #expect(observation.format == "text")
        #expect(observation.message == "Invalid request data")
    }

    @Test func fieldPathsRemainUsefulWhileURLsAndEmailsStayOut() {
        let message = ManagementDiagnosticRedaction.redact(
            "Invalid space_permissions.rules[0].roles spacePermissions "
                + "owner@space.com https://private.example.com/access", sensitive: []
        )
        #expect(message.contains("space_permissions") && message.contains("rules"))
        #expect(message.contains("spacePermissions") && message.contains("roles"))
        #expect(!message.contains("owner") && !message.contains("private"))
    }

    @Test func shortIdentifiersDoNotDestroyUnrelatedTechnicalWords() {
        let message = ManagementDiagnosticRedaction.redact(
            "Invalid space_permissions for a and me", sensitive: ["a", "me"]
        )
        #expect(message.contains("Invalid space_permissions for"))
        #expect(!message.hasSuffix("me"))
    }

    @Test func keepsTheReasonButDropsIdentifyingWordsAndOpaqueDetails() throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": [
            "code": 3,
            "message": "Invalid argument: space_permissions cannot be updated for Secret Space "
                + "space/abc someone@example.com opaqueSecretCredential123456.",
            "details": ["Cookie": "SID=secret", "account": "private-account"]
        ]])
        let observation = ManagementRefusalObservation(
            body,
            sensitive: ["Secret Space", "abc"]
        )
        #expect(observation.format == "json" && observation.code == 3)
        #expect(observation.message?.contains("space_permissions cannot be updated for") == true)
        let export = try String(decoding: JSONEncoder().encode(observation), as: UTF8.self)
        for secret in [
            "Secret Space",
            "abc",
            "someone",
            "example.com",
            "opaqueSecret",
            "SID",
            "private-account"
        ] {
            #expect(!export.contains(secret))
        }
    }

    @Test func protobufAndBase64StatusMessagesUseTheSameRedaction() {
        let message = Data("Invalid argument space_permissions opaqueSecret".utf8)
        let body = Data([8, 3, 18, UInt8(message.count)]) + message
        for input in [body, Data(body.base64EncodedString().utf8)] {
            let observation = ManagementRefusalObservation(
                input, sensitive: []
            )
            #expect(observation.code == 3)
            #expect(observation.message?.contains("space_permissions") == true)
            #expect(observation.message?.contains("opaqueSecret") == false)
        }
    }

    @Test func unrecognizedAndOversizedResponsesNeverBecomeRawReports() {
        for body in [Data("<html>secret sign-in page</html>".utf8), Data(repeating: 65, count: 16385)] {
            let observation = ManagementRefusalObservation(
                body, sensitive: []
            )
            #expect(observation.message == nil && observation.code == nil)
            #expect(observation.bodyBytes == body.count)
        }
    }

    @Test func pbliteKeepsOnlyTheStatusMessageAndKnownVocabulary() {
        let body = Data(#"[3,"Invalid target_audience: unknownPerson",{"private":"secret"}]"#.utf8)
        let observation = ManagementRefusalObservation(
            body, sensitive: []
        )
        #expect(observation.format == "pblite")
        #expect(observation.message?.contains("target_audience") == true)
        #expect(observation.message?.contains("unknownPerson") == false)
    }
}

extension ManagementRefusalObservationTests {
    @Test func decodesWrappedAndLegacyNativeRefusalsWithoutRawBytes() {
        let message = Data("Invalid argument".utf8)
        let status = Data([8, 3, 18, UInt8(message.count)]) + message
        #expect(status.count == 20)
        let wrapped = Data([10, UInt8(status.count)]) + status
        let legacy = Data([10, UInt8(message.count)]) + message + Data([16, 3])
        for body in [wrapped, legacy, Data(wrapped.base64EncodedString().utf8)] {
            let value = ManagementRefusalObservation(body, sensitive: [])
            #expect(value.code == 3)
            #expect(value.message == "Invalid argument")
            #expect(value.wireShape?.isEmpty == false)
        }
    }

    @Test func binaryRefusalsKeepOnlyRedactedPrintableWordsAndWireMetadata() throws {
        let body = Data([0, 255]) + Data("Invalid group_id secretUser123".utf8) + Data([0])
        let value = ManagementRefusalObservation(body, sensitive: [])
        #expect(value.format == "binary-text")
        #expect(value.message?.contains("Invalid group_id") == true)
        let report = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        #expect(!report.contains("secretUser123"))
    }
}

extension ManagementRefusalObservationTests {
    @Test(arguments: ["INVALID_PROTO", "INVALID_TOKEN", "INVALID_GROUP", "UNIMPLEMENTED"])
    func keepsOnlyKnownMachineReasonsInTheReportedNativeEnvelope(_ reason: String) throws {
        let body = Data([0x28, 0x90, 3, 0x48, 3, 0x52, UInt8(reason.utf8.count)]) + Data(reason.utf8)
        #expect(body.count == 20)
        let value = ManagementRefusalObservation(body, sensitive: [])
        #expect(value.format == "protobuf-raw-5-9-10")
        #expect(value.statusValues == ["5": 400, "9": 3])
        #expect(value.message == reason)
        let privateBody = Data([0x28, 0x90, 3, 0x48, 3, 0x52, 13]) + Data("PRIVATESECRET".utf8)
        let privateValue = ManagementRefusalObservation(privateBody, sensitive: [])
        #expect(privateValue.message == "[redacted]")
        let bytes = try JSONEncoder().encode(privateValue)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATESECRET"))
    }
}

extension ManagementRefusalObservationTests {
    @Test(arguments: [128, 400, 600, 1000, 16383])
    func nativeEnvelopeNumbersSurviveUnrecognizedOrBinaryReasons(_ number: Int) {
        let prefix = Data([0x28, UInt8(number & 127) | 128, UInt8(number >> 7), 0x48, 3, 0x52, 13])
        for reason in [Data("PRIVATESECRET".utf8), Data(repeating: 255, count: 13)] {
            let value = ManagementRefusalObservation(prefix + reason, sensitive: [])
            #expect(value.format == "protobuf-raw-5-9-10")
            #expect(value.statusValues == ["5": number, "9": 3])
            #expect(value.message == (String(data: reason, encoding: .utf8) == nil ? nil : "[redacted]"))
        }
    }
}

extension ManagementRefusalObservationTests {
    @Test func binaryMessageSetDetailsKeepSchemaAndEnumStructureWithoutTheirContents() {
        // Synthetic extension123456789, containing small enum fields1=3 and2=1.
        let detail = Data([11, 16, 0x95, 0x9A, 0xEF, 0x3A, 26, 4, 8, 3, 16, 1, 12])
        let body = Data([0x28, 0x90, 3, 0x48, 3, 0x52, 13]) + detail
        #expect(body.count == 20)
        let value = ManagementRefusalObservation(body, sensitive: [])
        #expect(value.statusValues == ["5": 400, "9": 3])
        #expect(value.wireShape?.contains("detail10:messageSet:123456789") == true)
        #expect(value.wireShape?.contains("detail10.extension123456789:1/0/1=3") == true)
        #expect(value.message == nil)
        let privateBytes = Data([10, 13]) + Data("PRIVATESECRET".utf8)
        let structure = ManagementBinaryDetailShape.describe(privateBytes)
        #expect(!structure.joined().contains("PRIVATESECRET"))
        #expect(ManagementBinaryDetailShape.describe(Data(detail.dropLast()))
            .allSatisfy { !$0.contains("messageSet") })
    }
}

extension ManagementRefusalObservationTests {
    @Test func onlyTheKnownApplicationErrorSchemaRevealsItsLargerCode() {
        // Public Dynamite application-error extension156118257, field1.
        // These codes are synthetic examples, not the value in the owner's report.
        let payloads: [(Int, [UInt8])] = [
            (20015, [8, 0xAF, 0x9C, 1]), (20016, [8, 0xB0, 0x9C, 1]),
            (30020, [8, 0xC4, 0xEA, 1]), (30052, [8, 0xE4, 0xEA, 1])
        ]
        for (code, payload) in payloads {
            let detail = Data([11, 16, 0xF1, 0xD9, 0xB8, 0x4A, 26, 4] + payload + [12])
            let body = Data([0x28, 0x90, 3, 0x48, 3, 0x52, 13]) + detail
            #expect(body.count == 20)
            let value = ManagementRefusalObservation(body, sensitive: [])
            #expect(value.wireShape?.contains("detail10:applicationCode=\(code)") == true)
            let other = Data([11, 16, 0x95, 0x9A, 0xEF, 0x3A, 26, 4] + payload + [12])
            #expect(!ManagementBinaryDetailShape.describe(other).joined().contains("applicationCode="))
            #expect(!ManagementBinaryDetailShape.describe(other).joined().contains("=\(code)"))
        }
    }
}

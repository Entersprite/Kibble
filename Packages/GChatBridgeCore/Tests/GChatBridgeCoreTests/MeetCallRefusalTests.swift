import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallRefusalTests {
    @Test func jsonRetainsOnlyFixedErrorLabels() {
        let body = Data(
            #"""
            {"error":{"code":403,"status":"PERMISSION_DENIED","message":"private-message","details":[{
                "@type":"type.googleapis.com/google.rpc.ErrorInfo",
                "reason":"API_KEY_HTTP_REFERRER_BLOCKED",
                "metadata":{"url":"https://meet.google.com/call?secret=private-url"}
            }]}}
            """#
            .utf8
        )
        let refusal = MeetCallRefusal(body: body)
        #expect(refusal.bodyKind == .json)
        #expect(refusal.code == 403)
        #expect(refusal.status == .permissionDenied)
        #expect(refusal.reason == .apiKeyReferrerBlocked)
        #expect(refusal.safeDescription.contains("private") == false)
    }

    @Test func unrecognizedReasonAndStatusAreNotPrinted() {
        let body = Data(
            #"""
            {"error":{"code":403,"status":"PRIVATE_STATUS","details":[{
                "@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"PRIVATE_REASON"
            }]}}
            """#
            .utf8
        )
        let refusal = MeetCallRefusal(body: body)
        #expect(refusal.status == nil)
        #expect(refusal.reason == nil)
        #expect(refusal.safeDescription.contains("PRIVATE") == false)
    }

    @Test func base64StatusRetainsTheCodeAndDiscardsItsMessage() {
        let message = Data("private-message".utf8)
        let bytes = Data([0x08, 0x07, 0x12, UInt8(message.count)]) + message
        for body in [bytes, Data(bytes.base64EncodedString().utf8)] {
            let refusal = MeetCallRefusal(body: body)
            #expect(refusal.bodyKind == .protobuf)
            #expect(refusal.code == 7)
            #expect(refusal.safeDescription.contains("private-message") == false)
        }
    }

    @Test func unknownBodiesDoNotBecomeStatusCodes() {
        #expect(MeetCallRefusal(body: Data()).bodyKind == .empty)
        #expect(MeetCallRefusal(body: Data("<html>private-sentinel</html>".utf8)).bodyKind == .other)
        #expect(MeetCallRefusal(body: Data([0x08, 0x7F])).code == nil)
        #expect(MeetCallRefusal(body: Data([0x08, 0x07, 0x12, 0x7F])).code == nil)
    }

    @Test func captureLockRefusalRequiresTheExactProtobufPermissionDenial() {
        let message = MeetProto.string(2, "Unsupported audio/video lock")
        let rejection = MeetProto.number(1, 7) + message
        let encodedRejection = Data(rejection.base64EncodedString().utf8)
        #expect(MeetCallRefusal(body: rejection).isUnsupportedCaptureLock)
        #expect(MeetCallRefusal(body: encodedRejection).isUnsupportedCaptureLock)
        #expect(!MeetCallRefusal(body: MeetProto.number(1, 16) + message).isUnsupportedCaptureLock)
        let different = MeetProto.number(1, 7) + MeetProto.string(2, "Audio and video are unsupported")
        #expect(!MeetCallRefusal(body: different).isUnsupportedCaptureLock)
        let json = #"""
        {"error":{"code":403,"status":"PERMISSION_DENIED","message":"Unsupported audio/video lock"}}
        """#
        #expect(!MeetCallRefusal(body: Data(json.utf8)).isUnsupportedCaptureLock)
    }

    @Test func aConferenceEndRequiresTheExactProtobufPreconditionRefusal() {
        let message = MeetProto.string(2, "The conference is gone.")
        let status = MeetProto.number(1, 9) + message
        for body in [status, Data(status.base64EncodedString().utf8)] {
            let refusal = MeetCallRefusal(body: body)
            #expect(refusal.isEndedConference)
            #expect(!refusal.safeDescription.contains("conference"))
        }
        #expect(!MeetCallRefusal(body: MeetProto.number(1, 7) + message).isEndedConference)
        let similar = MeetProto.number(1, 9) + MeetProto.string(2, "The conference is gone for this device.")
        #expect(!MeetCallRefusal(body: similar).isEndedConference)
        let generic = MeetProto.number(1, 9)
        #expect(!MeetCallRefusal(body: generic).isEndedConference)
    }

    @Test func jsonBadRequestRetainsOnlyRecognizedCategories() throws {
        let paths = [
            "mediaSession.clientConfig.dtlsConfig.fingerprint", "client_config.stun_config.password",
            "clientConfig.iceConfig.ufrag", "clientConfig.codecs[0].name",
            "clientConfig.rtpHeaderExtensions[0].uri", "clientConfig",
            "clientConfig.private-sentinel", "private-sentinel", "clientConfig.codecsSecret",
            "clientConfig." + String(repeating: "x", count: 512)
        ]
        let body = try JSONSerialization.data(withJSONObject: ["error": [
            "code": 400, "message": "private-sentinel", "details": [[
                "@type": "type.googleapis.com/google.rpc.BadRequest",
                "fieldViolations": paths.map { ["field": $0, "description": "private-sentinel"] }
            ]]
        ]])
        let refusal = MeetCallRefusal(body: body)
        #expect(refusal.invalidFields == [.dtls, .ice, .codecs, .extensions, .media])
        #expect(!refusal.safeDescription.contains("private-sentinel"))
        #expect(!refusal.safeDescription.contains("password"))
    }

    @Test func protobufBadRequestSupportsRawAndBase64WithoutRetainingPrivateDetails() {
        let request = [
            "media_session.client_config.dtls_config.fingerprint",
            "client_config.stun_config.password", "client_config.codecs[0].name",
            "client_config.rtp_header_extensions[0].uri", "client_config",
            "private-sentinel", "client_config.dtls_config.fingerprint"
        ].reduce(into: Data()) { data, path in
            data += MeetProto.bytes(
                1,
                MeetProto.string(1, path)
                    + MeetProto.string(2, "private-sentinel")
            )
        }
        let detail = MeetProto.string(1, "type.googleapis.com/google.rpc.BadRequest")
            + MeetProto.bytes(2, request)
        let status = MeetProto.number(1, 3) + MeetProto.string(2, "private-sentinel")
            + MeetProto.bytes(3, detail)
        for body in [status, Data(status.base64EncodedString().utf8)] {
            let refusal = MeetCallRefusal(body: body)
            #expect(refusal.code == 3)
            #expect(refusal.invalidFields == [.dtls, .ice, .codecs, .extensions, .media])
            #expect(!refusal.safeDescription.contains("private-sentinel"))
            #expect(!refusal.safeDescription.contains("fingerprint"))
        }
    }

    @Test func malformedOrWrongTypeDetailsCannotClaimARejectedCategory() {
        let violation = MeetProto.string(1, "client_config.dtls_config")
        let validRequest = MeetProto.bytes(1, violation)
        let type = MeetProto.string(1, "type.googleapis.com/google.rpc.BadRequest")
        let details = [
            type + MeetProto.bytes(2, validRequest + Data([0x80])),
            type + MeetProto.bytes(2, MeetProto.bytes(1, violation + Data([0x80]))),
            type + MeetProto.bytes(2, validRequest) + MeetProto.bytes(2, validRequest),
            MeetProto.string(1, "private-sentinel") + MeetProto.bytes(2, validRequest)
        ]
        for detail in details {
            let refusal = MeetCallRefusal(body: MeetProto.number(1, 3) + MeetProto.bytes(3, detail))
            #expect(refusal.code == 3)
            #expect(refusal.invalidFields.isEmpty)
            #expect(!refusal.safeDescription.contains("private-sentinel"))
        }
    }

    @Test func messageVocabularyWorksWithoutBadRequestAndNeverCopiesServerText() throws {
        let message = "Missing DTLS fingerprint for codec opus in client_config: private-sentinel "
            + "https://meet.google.com/private-url?token=private-token"
        let status = MeetProto.number(1, 3) + MeetProto.string(2, message)
        let json = try JSONSerialization.data(withJSONObject: ["error": ["code": 400, "message": message]])
        for body in [status, Data(status.base64EncodedString().utf8), json] {
            let refusal = MeetCallRefusal(body: body)
            #expect(refusal.messageKind == .classified)
            #expect(refusal.messageTopics == [.missing, .dtls, .codecs, .configuration])
            #expect(refusal.invalidFields.isEmpty)
            #expect(refusal.safeDescription.contains("message topics: missing requirements, DTLS/SRTP"))
            for privateValue in [
                "private-sentinel",
                "private-url",
                "private-token",
                "fingerprint",
                "https://"
            ] {
                #expect(!refusal.safeDescription.contains(privateValue))
            }
        }
    }

    @Test func messageClassificationDoesNotPretendUnknownTextIsADiagnosis() {
        for (message, kind) in [
            ("", MeetCallRefusal.MessageKind.absent),
            ("Invalid argument: private-sentinel", .unclassified),
            (String(repeating: "DTLS ", count: 1700), .oversized)
        ] {
            let refusal = MeetCallRefusal(body: MeetProto.number(1, 3) + MeetProto.string(2, message))
            #expect(refusal.messageKind == kind)
            #expect(refusal.messageTopics.isEmpty)
            #expect(refusal.safeDescription == "error body protobuf; code 3")
        }
        let absent = MeetCallRefusal(body: MeetProto.number(1, 3))
        #expect(absent.messageKind == .absent)
        #expect(absent.messageTopics.isEmpty)
    }

    @Test func duplicateOrInvalidUTF8MessagesAreNotClassified() {
        for message in [
            MeetProto.string(2, "DTLS") + MeetProto.string(2, "codec"),
            MeetProto.bytes(2, Data([0xFF]))
        ] {
            let refusal = MeetCallRefusal(body: MeetProto.number(1, 3) + message)
            #expect(refusal.messageKind == .malformed)
            #expect(refusal.messageTopics.isEmpty)
        }
    }

    @Test func technicalTopicsRequireWholeWordsAndHaveAFixedOrder() {
        let message = "privateCodecSentinel transport unsupported video channels audio ICE protobuf "
            + "RTP extensions config missing SRTP codec codec"
        let refusal = MeetCallRefusal(body: MeetProto.number(1, 3) + MeetProto.string(2, message))
        #expect(refusal.messageTopics == [
            .missing, .unsupported, .parsing, .dtls, .ice, .codecs, .extensions, .configuration,
            .audio, .video, .transport, .channels
        ])
        let privateWord = MeetCallRefusal(body: MeetProto.number(1, 3)
            + MeetProto.string(2, "privateCodecSentinel privateDTLSSentinel"))
        #expect(privateWord.messageTopics.isEmpty)
    }
}

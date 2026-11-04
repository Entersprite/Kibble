import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetDeviceAcknowledgementTests {
    private let name = "spaces/demo/devices/native"

    @Test func returnedRequirementsProduceOnlyTheNativeAcknowledgementPayload() throws {
        let raw = MeetProto.string(1, name) + MeetProto.number(4, 9)
            + MeetProto.bytes(
                41,
                MeetProto.number(1, 3) + MeetProto.number(2, 1) + MeetProto.string(4, "metadata")
            )
        let device = try MeetDeviceWire.device(from: Data(raw.base64EncodedString().utf8), in: "spaces/demo")
        #expect(device.acknowledgements == [.init(type: 3, state: 1)])
        let body = try MeetDeviceWire.acknowledge(device: name, requirements: device.acknowledgements)
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1])
        let value = try MeetProto.payload(1, body)
        #expect(ProtoFieldScan.fields(in: value).fields.map(\.number) == [1, 41])
        #expect(try MeetProto.text(1, value) == name)
        let requirement = try MeetProto.payload(41, value)
        #expect(try MeetProto.value(1, requirement) == 3)
        #expect(try MeetProto.value(2, requirement) == 2)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: requirement).isEmpty)
    }

    @Test(arguments: [UInt64(0), 6, 7, 99, UInt64.max])
    func unknownOrUnsupportedTypesCannotBeAcknowledged(_ type: UInt64) {
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetDeviceWire.acknowledge(device: name, requirements: [.init(type: type, state: 1)])
        }
    }

    @Test func aJoinedBrowserCannotSupplyTheNativeDevicesAdmissionOrNotices() throws {
        let own = MeetProto.string(1, name) + MeetProto.number(4, 9)
            + MeetProto.bytes(41, MeetProto.number(1, 3) + MeetProto.number(2, 1))
        let browser = MeetProto.string(1, "spaces/demo/devices/browser") + MeetProto.number(4, 1)
            + MeetProto.bytes(41, MeetProto.number(1, 1) + MeetProto.number(2, 1))
        func response(_ entries: [Data]) -> Data {
            let full = entries.reduce(into: MeetProto.bytes(1, Data())) { $0 += MeetProto.bytes(2, $1) }
            return Data(MeetProto.bytes(2, MeetProto.bytes(2, full)).base64EncodedString().utf8)
        }
        let selected = try MeetCallCollectionsWire.admissionDevice(
            from: response([browser, own]), in: "spaces/demo", name: name
        )
        #expect(selected?.joinState == 9 && selected?.acknowledgements == [.init(type: 3, state: 1)])
        #expect(try MeetCallCollectionsWire.admissionDevice(
            from: response([browser]), in: "spaces/demo", name: name
        ) == nil)
        #expect(throws: (any Error).self) {
            try MeetCallCollectionsWire.admissionDevice(
                from: response([own, own]),
                in: "spaces/demo",
                name: name
            )
        }
    }

    @Test func malformedLocalRequirementsRefuseWithoutBreakingOtherDeviceCollections() throws {
        let good = MeetProto.string(1, name) + MeetProto.number(4, 9)
        for fields in [
            MeetProto.number(41, 1),
            MeetProto.bytes(41, Data([128])),
            MeetProto.bytes(41, Data(repeating: 0, count: 4097)),
            MeetProto.bytes(41, MeetProto.number(1, 1)) + MeetProto.bytes(41, MeetProto.number(1, 1))
        ] {
            let raw = good + fields
            #expect(throws: (any Error).self) {
                try MeetDeviceWire.device(from: Data(raw.base64EncodedString().utf8), in: "spaces/demo")
            }
            #expect(try MeetDeviceWire.devicePayload(raw, in: "spaces/demo").name == name)
        }
        #expect(throws: (any Error).self) {
            try MeetDeviceWire.acknowledge(device: name, requirements: [.init(type: 1, state: 2)])
        }
    }
}

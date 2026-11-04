import Foundation

public extension MeetMediaSessionWire {
    enum StreamControlFailure: String, Error, Sendable, Equatable {
        case configuration = "malformed server configuration"
        case channelList = "invalid server channel list"
        case descriptor = "malformed dcrpc descriptor"
        case ambiguous = "multiple dcrpc descriptors"
        case missingIdentifier = "missing assigned SCTP identifier"
        case identifier = "invalid assigned SCTP identifier"
        case ordering = "invalid ordered flag"
        case reliability = "invalid channel reliability flag"
        case reliabilityEncoding = "invalid channel reliability encoding"
        case reliabilityLimit = "channel reliability limit outside supported range"
        case compression = "unsupported channel compression"
    }

    struct StreamControlChannel: Sendable, Equatable {
        public let id: UInt16
        public let ordered: Bool
        public let maxPacketLifeTime: UInt16?
        public let maxRetransmits: UInt16?
    }

    /// Server config12 assigns SCTP streams. The native converter uses these
    /// IDs with negotiated=true; creating another channel with the label alone
    /// does not bind that channel to the assigned application stream.
    static func streamControlChannel(serverConfiguration data: Data) throws -> StreamControlChannel? {
        guard data.count <= 500_000 else { throw StreamControlFailure.configuration }
        do { try MeetProto.validate(data) } catch { throw StreamControlFailure.configuration }
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == 12 }
        let channels = ProtoFieldScan.payloads(ofField: 12, in: data)
        guard fields.count <= 32, fields.count == channels.count else {
            throw StreamControlFailure.channelList
        }
        let selected = channels.filter {
            ProtoFieldScan.payloads(ofField: 1, in: $0).contains(Data("dcrpc".utf8))
        }
        guard selected.count <= 1 else { throw StreamControlFailure.ambiguous }
        guard let channel = selected.first else { return nil }
        return try assignedControlChannel(channel)
    }

    private static func assignedControlChannel(_ channel: Data) throws -> StreamControlChannel {
        do { _ = try MeetProto.text(1, channel) } catch { throw StreamControlFailure.descriptor }
        guard let id = try channelValue(3, channel, failure: .identifier) else {
            throw StreamControlFailure.missingIdentifier
        }
        guard id < 65535 else { throw StreamControlFailure.identifier }
        let ordered = try channelValue(2, channel, failure: .ordering) ?? 0
        guard ordered <= 1 else { throw StreamControlFailure.ordering }
        let reliability = try channelReliability(channel)
        // Native CKh maps an unspecified preference0 to NONE, just as an
        // absent preference does. GZIP2 requires framing we do not advertise.
        guard try (channelCompression(channel).first ?? 0) <= 1 else {
            throw StreamControlFailure.compression
        }
        return StreamControlChannel(
            id: UInt16(id), ordered: ordered == 1,
            maxPacketLifeTime: reliability.lifetime, maxRetransmits: reliability.retransmits
        )
    }

    private static func channelReliability(_ data: Data) throws -> (lifetime: UInt16?, retransmits: UInt16?) {
        // Native schema reliability is oneof4/5/6. Its final wire member wins,
        // including an explicitly selected zero lifetime/retransmission limit.
        guard let field = ProtoFieldScan.fields(in: data).fields.last(where: {
            [4, 5, 6].contains($0.number)
        }) else { return (nil, nil) }
        guard field.wireType == 0,
              let value = ProtoFieldScan.varintValues(ofField: field.number, in: data).last else {
            throw StreamControlFailure.reliabilityEncoding
        }
        if field.number == 4 {
            guard value <= 1 else { throw StreamControlFailure.reliability }
            return (nil, nil)
        }
        guard value <= UInt16.max else { throw StreamControlFailure.reliabilityLimit }
        return field.number == 5 ? (UInt16(value), nil) : (nil, UInt16(value))
    }

    private static func channelValue(
        _ field: Int, _ data: Data, failure: StreamControlFailure
    ) throws -> UInt64? {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return nil }
        do { return try MeetProto.value(field, data) } catch { throw failure }
    }

    private static func channelCompression(_ data: Data) throws -> [UInt64] {
        var scalars = ProtoFieldScan.varintValues(ofField: 7, in: data).makeIterator()
        var packed = ProtoFieldScan.payloads(ofField: 7, in: data).makeIterator()
        var values: [UInt64] = []
        for field in ProtoFieldScan.fields(in: data).fields where field.number == 7 {
            switch field.wireType {
            case 0:
                guard let value = scalars.next() else { throw StreamControlFailure.compression }
                values.append(value)
            case 2:
                guard let bytes = packed.next(), bytes.count <= 8 else {
                    throw StreamControlFailure.compression
                }
                values += bytes.map(UInt64.init)
            default: throw StreamControlFailure.compression
            }
        }
        guard values.count <= 8, values.allSatisfy({ $0 <= 2 }) else {
            throw StreamControlFailure.compression
        }
        return values
    }
}

import Foundation

public extension MeetMediaSessionWire {
    enum ActivityChannel: String, CaseIterable, Sendable {
        case reactions
        case messages = "meet_messages"
        case captions = "captions_v2"
    }

    enum ChannelCompression: Sendable, Equatable {
        case none
        case gzip
    }

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
        public let compression: ChannelCompression
    }

    /// Server config12 assigns SCTP streams. The native converter uses these
    /// IDs with negotiated=true; creating another channel with the label alone
    /// does not bind that channel to the assigned application stream.
    static func streamControlChannel(serverConfiguration data: Data) throws -> StreamControlChannel? {
        let channels = try channelDescriptors(in: data)
        let selected = channels.filter { hasLabel("dcrpc", in: $0) }
        guard selected.count <= 1 else { throw StreamControlFailure.ambiguous }
        guard let channel = selected.first else { return nil }
        return try assignedControlChannel(channel)
    }

    static func requestingActivityChannels(in configuration: Data, allowsGzipCaptions: Bool = false) -> Data {
        ActivityChannel.allCases.reduce(configuration) { result, activity in
            // The native caption service responds on NONE. Keep GZIP available
            // when supported without preferring it over the working plain route.
            let compression = activity == .captions && allowsGzipCaptions
                ? MeetProto.bytes(7, Data([1, 2])) : MeetProto.number(7, 1)
            let descriptor = MeetProto.string(1, activity.rawValue) + MeetProto.number(2, 1)
                + MeetProto.number(4, 1) + compression
            return result + MeetProto.bytes(17, descriptor)
        }
    }

    /// An unusable optional assignment withholds that activity alone.
    static func activityChannels(serverConfiguration data: Data, allowsGzipCaptions: Bool = false) throws
        -> [ActivityChannel: StreamControlChannel] {
        let channels = try channelDescriptors(in: data)
        let ids = channels.flatMap { Set(ProtoFieldScan.varintValues(ofField: 3, in: $0)) }
        return Dictionary(uniqueKeysWithValues: ActivityChannel.allCases.compactMap { activity in
            let selected = channels.filter { hasLabel(activity.rawValue, in: $0) }
            let allowsGzip = activity == .captions && allowsGzipCaptions
            guard selected.count == 1, let descriptor = selected.first,
                  let channel = try? assignedControlChannel(descriptor, allowsGzip: allowsGzip),
                  ids.filter({ $0 == UInt64(channel.id) }).count == 1 else { return nil }
            return (activity, channel)
        })
    }

    private static func hasLabel(_ label: String, in descriptor: Data) -> Bool {
        ProtoFieldScan.payloads(ofField: 1, in: descriptor).contains(Data(label.utf8))
    }

    private static func channelDescriptors(in data: Data) throws -> [Data] {
        guard data.count <= 500_000 else { throw StreamControlFailure.configuration }
        do { try MeetProto.validate(data) } catch { throw StreamControlFailure.configuration }
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == 12 }
        let channels = ProtoFieldScan.payloads(ofField: 12, in: data)
        guard fields.count <= 32, fields.count == channels.count else {
            throw StreamControlFailure.channelList
        }
        return channels
    }

    private static func assignedControlChannel(
        _ channel: Data, allowsGzip: Bool = false
    ) throws -> StreamControlChannel {
        do { _ = try MeetProto.text(1, channel) } catch { throw StreamControlFailure.descriptor }
        guard let id = try channelValue(3, channel, failure: .identifier) else {
            throw StreamControlFailure.missingIdentifier
        }
        guard id < 65535 else { throw StreamControlFailure.identifier }
        let ordered = try channelValue(2, channel, failure: .ordering) ?? 0
        guard ordered <= 1 else { throw StreamControlFailure.ordering }
        let reliability = try channelReliability(channel)
        // The first server preference is binding. Unspecified behaves like NONE.
        let preferredCompression = try channelCompression(channel).first ?? 0
        guard preferredCompression <= 1 || (allowsGzip && preferredCompression == 2) else {
            throw StreamControlFailure.compression
        }
        return StreamControlChannel(
            id: UInt16(id), ordered: ordered == 1,
            maxPacketLifeTime: reliability.lifetime, maxRetransmits: reliability.retransmits,
            compression: preferredCompression == 2 ? .gzip : .none
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

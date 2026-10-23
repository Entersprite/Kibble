import Foundation

/// Camera and presentation stream controls on the current native session's dcrpc channel.
public enum MeetVideoStreamWire {
    public struct Context: Sendable, Equatable {
        let session: String
        let conference: String

        public init(mediaSession: String, conferenceID: String) throws {
            guard MeetDeviceWire.validMediaSession(mediaSession), valid(conferenceID) else {
                throw MeetCallWire.WireError.invalidIdentifier
            }
            session = String(mediaSession.dropFirst(14)); conference = conferenceID
        }

        func identity(direction: UInt64, stream: String) -> Data {
            MeetProto.number(1, direction) + MeetProto.number(2, 2)
                + MeetProto.string(3, session) + MeetProto.string(4, stream) + MeetProto.string(5, conference)
        }

        func matches(_ data: Data, direction: UInt64, kind: UInt64 = 2, stream: String) throws -> Bool {
            try MeetProto.value(1, data) == direction && MeetProto.value(2, data) == kind
                && MeetProto.text(4, data) == stream && inherited(3, data, expected: session)
                && inherited(5, data, expected: conference)
        }
    }

    public struct Downstream: Sendable, Equatable {
        public let source: MeetVideoSource
        public let muted: Bool
        public let isCamera: Bool
        let id: String
        let descriptor: Data
        let context: Context
    }

    public static func register(
        context: Context,
        source: MeetVideoSource,
        camera: Bool = true,
        requestID: UInt64,
        header: Data
    ) throws -> Data {
        let stream = context.identity(direction: 2, stream: "video") + MeetProto.bytes(8, source.protobuf)
            + MeetProto.bytes(10, MeetProto.number(1, 1)) + MeetProto.number(11, camera ? 1 : 0)
        return try request(
            variant: 4,
            body: MeetProto.bytes(3, Data()) + MeetProto.bytes(4, stream),
            id: requestID,
            header: header
        )
    }

    public static func mute(context: Context, muted: Bool, requestID: UInt64, header: Data) throws -> Data {
        let stream = context.identity(direction: 2, stream: "video") + MeetProto.bytes(
            10,
            MeetProto.number(1, muted ? 1 : 0)
        )
        return try request(
            variant: 2,
            body: MeetProto.bytes(3, Data()) + MeetProto.bytes(4, stream),
            id: requestID,
            header: header
        )
    }

    public static func confirm(
        from data: Data,
        context: Context,
        source: MeetVideoSource? = nil,
        muted: Bool,
        camera: Bool? = nil,
        requestID: UInt64
    ) throws {
        let operation = try response(data, variant: source == nil ? 2 : 5, id: requestID)
        let echoes = ProtoFieldScan.payloads(ofField: 4, in: operation)
        guard echoes.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        guard let echo = echoes.first else { return }
        guard try context.matches(echo, direction: 2, stream: "video"), try flag(10, echo) == muted else {
            throw MeetCallWire.WireError.malformedResponse
        }
        if let camera, try flag(11, echo) != camera {
            throw MeetCallWire.WireError.malformedResponse
        }
        if let source {
            guard try MeetVideoSource.parse(MeetProto.payload(8, echo)) == source
            else { throw MeetCallWire.WireError.malformedResponse }
        }
    }

    public static func search(context: Context, requestID: UInt64, header: Data) throws -> Data {
        try request(
            variant: 3,
            body: MeetProto.number(2, 1) + MeetProto.string(3, context.session)
                + MeetProto.bytes(5, Data()),
            id: requestID,
            header: header
        )
    }

    /// Search is scoped by its request. Explicit foreign parents still reject;
    /// audio and unsupported video source layouts stay unselected.
    public static func downstreams(
        from data: Data,
        context: Context,
        requestID: UInt64
    ) throws -> [Downstream] {
        let operation = try response(data, variant: 3, id: requestID)
        let streams = ProtoFieldScan.payloads(ofField: 2, in: operation)
        guard streams.count <= 64 else { throw MeetCallWire.WireError.malformedResponse }
        var result: [Downstream] = []
        for stream in streams {
            guard try MeetProto.value(1, stream) == 1 else { throw MeetCallWire.WireError.malformedResponse }
            guard try MeetProto.value(2, stream) == 2 else { continue }
            let id = try MeetProto.text(4, stream)
            guard valid(id),
                  try context.matches(stream, direction: 1, stream: id)
            else { throw MeetCallWire.WireError.malformedResponse }
            let camera = try flag(11, stream)
            guard let source = try? MeetVideoSource.parse(MeetProto.payload(8, stream)) else { continue }
            let muted = try flag(10, stream)
            guard !result.contains(where: { $0.id == id || $0.source == source })
            else { throw MeetCallWire.WireError.malformedResponse }
            result.append(Downstream(
                source: source,
                muted: muted,
                isCamera: camera,
                id: id,
                descriptor: stream,
                context: context
            ))
        }
        return result
    }

    /// Prefer one active presentation, then one camera. Ambiguous active
    /// presenters or cameras are not assigned to a single receiving slot.
    public static func preferred(_ streams: [Downstream]) -> Downstream? {
        let presentations = streams.filter { !$0.isCamera && !$0.muted }
        if !presentations.isEmpty {
            return presentations.count == 1 ? presentations[0] : nil
        }
        let cameras = streams.filter(\.isCamera)
        return cameras.count == 1 ? cameras[0] : nil
    }

    public static func view(
        context: Context,
        stream: Downstream,
        requestID: UInt64,
        header: Data
    ) throws -> Data {
        guard stream.context == context else { throw MeetCallWire.WireError.invalidIdentifier }
        let selection = MeetProto.number(2, 1) + MeetProto.bytes(
            3,
            MeetProto.number(1, 720)
                + MeetProto.number(2, 1280) + MeetProto.number(3, 30)
        )
        var value = context.identity(direction: 1, stream: stream.id) + MeetProto.bytes(
            8,
            stream.source.protobuf
        )
            + MeetProto.bytes(9, selection)
        if ProtoFieldScan.fields(in: stream.descriptor).fields.contains(where: { $0.number == 6 }) {
            try value += MeetProto.bytes(6, MeetProto.payload(6, stream.descriptor))
        }
        return try request(
            variant: 2,
            body: MeetProto.bytes(3, Data()) + MeetProto.bytes(4, value),
            id: requestID,
            header: header
        )
    }

    public static func confirmView(
        from data: Data,
        context: Context,
        stream: Downstream,
        requestID: UInt64
    ) throws {
        guard stream.context == context else { throw MeetCallWire.WireError.invalidIdentifier }
        let operation = try response(data, variant: 2, id: requestID)
        let streams = ProtoFieldScan.payloads(ofField: 4, in: operation)
        guard streams.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        if let echo = streams.first {
            guard try context.matches(echo, direction: 1, stream: stream.id),
                  try MeetVideoSource.parse(MeetProto.payload(8, echo)) == stream.source
            else { throw MeetCallWire.WireError.malformedResponse }
        }
    }

    private static func request(variant: UInt64, body: Data, id: UInt64, header: Data) throws -> Data {
        guard (1 ... UInt64(UInt32.max)).contains(id), !header.isEmpty,
              header.count <= 10000 else { throw MeetCallWire.WireError.invalidIdentifier }
        try MeetProto.validate(header)
        return MeetProto.number(1, id) + MeetProto.bytes(variant, MeetProto.bytes(1, header) + body)
    }

    private static func response(_ data: Data, variant: Int, id: UInt64) throws -> Data {
        guard data.count <= 1_000_000,
              try MeetProto.value(1, data) == id else { throw MeetCallWire.WireError.malformedResponse }
        let status = try MeetProto.payload(4, data)
        try MeetProto.validate(status)
        let code = try ProtoFieldScan.fields(in: status).fields
            .contains(where: { $0.number == 1 }) ? MeetProto.value(
                1,
                status
            ) : 0
        let variants = ProtoFieldScan.fields(in: data).fields.filter { [2, 3, 5].contains($0.number) }
        guard code == 0, variants.count == 1,
              variants[0].number == variant else { throw MeetCallWire.WireError.malformedResponse }
        let operation = try MeetProto.payload(variant, data), header = try MeetProto.payload(1, operation)
        guard try MeetProto.value(1, header) == 1 else { throw MeetCallWire.WireError.malformedResponse }
        return operation
    }

    private static func flag(_ field: Int, _ data: Data) throws -> Bool {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return false }
        if field == 11 {
            let value = try MeetProto.value(field, data)
            guard value <= 1 else { throw MeetCallWire.WireError.malformedResponse }
            return value == 1
        }
        let value = try MeetProto.payload(field, data)
        guard !value.isEmpty else { return false }
        let number = try MeetProto.value(1, value)
        guard number <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        return number == 1
    }

    private static func inherited(_ field: Int, _ data: Data, expected: String) throws -> Bool {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return true }
        let value = try MeetProto.payload(field, data)
        return value.isEmpty || String(data: value, encoding: .utf8) == expected
    }

    private static func valid(_ value: String) -> Bool {
        value.utf8.count <= 128 && MeetAudioOffer
            .atom(value)
    }
}

public extension MeetVideoStreamWire {
    /// The other person's microphone in a one-to-one call, read from the same
    /// DOWN search reply as video: audio entries (kind 1) carry mute10.1. Only
    /// a single audio entry can be attributed to that person; none, several,
    /// or one without field 10 is unknown (nil), never muted. Video entries
    /// and their own mute flags are not consulted.
    static func remoteAudioMuted(from data: Data, context: Context, requestID: UInt64) throws -> Bool? {
        let operation = try response(data, variant: 3, id: requestID)
        let streams = ProtoFieldScan.payloads(ofField: 2, in: operation)
        guard streams.count <= 64 else { throw MeetCallWire.WireError.malformedResponse }
        var audio: [Data] = []
        for stream in streams {
            guard try MeetProto.value(1, stream) == 1 else { throw MeetCallWire.WireError.malformedResponse }
            guard try MeetProto.value(2, stream) == 1 else { continue }
            let id = try MeetProto.text(4, stream)
            guard valid(id), try context.matches(stream, direction: 1, kind: 1, stream: id)
            else { throw MeetCallWire.WireError.malformedResponse }
            audio.append(stream)
        }
        guard audio.count == 1, let stream = audio.first else { return nil }
        guard ProtoFieldScan.fields(in: stream).fields.contains(where: { $0.number == 10 })
        else { return nil }
        return try flag(10, stream)
    }
}

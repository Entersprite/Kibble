import Foundation

/// Why a chunk's contents could not be read.
///
/// Every case is a shape the protocol is not supposed to produce. They are
/// refused rather than coerced because the alternative is worse than an error:
/// a misread `aid` does not fail, it silently replays or skips events.
public enum ChannelChunkError: Error, Hashable, CustomStringConvertible {
    /// The chunk was valid JSON but not `[[aid, data], ...]`.
    case notAnArrayOfArrays

    /// An entry was not the expected `[aid, data]` pair.
    case malformedArray(index: Int)

    /// An `aid` was present but was not an integer.
    case nonIntegerAid(index: Int)

    /// The initial response did not carry a SID at `[0][1][1]`.
    case noSessionIdentifier

    public var description: String {
        switch self {
        case .notAnArrayOfArrays:
            "a chunk was not an array of [aid, data] pairs"
        case let .malformedArray(index):
            "chunk entry \(index) was not an [aid, data] pair"
        case let .nonIntegerAid(index):
            "chunk entry \(index) had a non-integer aid"
        case .noSessionIdentifier:
            "the initial response carried no SID at [0][1][1]"
        }
    }
}

/// One `[aid, data]` entry from the channel.
///
/// Named for the reference's `on_receive_array`, because that is what a future
/// reader will be comparing against.
public struct ChannelArray: Sendable, Hashable {
    /// The acknowledgement counter. The **highest fully processed** one is what
    /// a steady-state reopen sends back as `AID`, so it advances after an array
    /// has been handled rather than when it is received — a client that
    /// acknowledges on receipt loses whatever it was in the middle of when the
    /// connection dropped.
    public let aid: Int

    /// The payload, still untyped. Turning it into a domain event is a
    /// different layer's job; this one only has to get the boundaries right.
    public let data: PBLiteValue

    public init(aid: Int, data: PBLiteValue) {
        self.aid = aid
        self.data = data
    }

    /// Whether this is the server saying nothing in particular.
    ///
    /// Exactly `["noop"]`. Not "contains noop": a payload that merely mentions
    /// it is a real event, and treating it as a keepalive would drop it
    /// silently. Keepalives still carry an `aid` and still advance the
    /// watermark.
    public var isKeepalive: Bool {
        data == .array([.string("noop")])
    }
}

/// Reading the contents of a framed chunk.
///
/// Framing is `ChunkParser`'s job and stops at the payload's boundaries. This
/// is the next layer in: `[[aid, data], ...]`, plus the one special case the
/// handshake needs.
public enum ChannelChunk {
    /// Parses `[[aid, data], ...]`.
    public static func arrays(in payload: String) throws -> [ChannelArray] {
        let value = try PBLiteValue(json: Data(payload.utf8))
        guard let entries = value.arrayValue else {
            throw ChannelChunkError.notAnArrayOfArrays
        }
        return try entries.enumerated().map { index, entry in
            guard let pair = entry.arrayValue, pair.count >= 2 else {
                throw ChannelChunkError.malformedArray(index: index)
            }
            guard let aid = pair[0].intValue else {
                throw ChannelChunkError.nonIntegerAid(index: index)
            }
            return ChannelArray(aid: aid, data: pair[1])
        }
    }

    /// The SID, from the body of the `X-HTTP-Initial-Response` header.
    ///
    /// `res[0][1][1]` — the reference's exact expression (`channel.py:124-134`).
    /// Spelled out here rather than generalised because it is a fixed position
    /// in a fixed message, and a lookup that searched for something
    /// string-shaped would happily find the wrong field the day the shape
    /// changes.
    public static func sid(inInitialResponse response: String) throws -> String {
        let value = try PBLiteValue(json: Data(response.utf8))
        guard
            let outer = value.arrayValue, let first = outer.first?.arrayValue,
            first.count >= 2, let inner = first[1].arrayValue,
            inner.count >= 2
        else {
            throw ChannelChunkError.noSessionIdentifier
        }
        guard let sid = inner[1].stringValue else {
            throw ChannelChunkError.noSessionIdentifier
        }
        return sid
    }
}

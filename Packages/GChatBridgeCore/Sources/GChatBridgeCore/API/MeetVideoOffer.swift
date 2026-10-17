import Foundation

/// Bundled native audio, a single VP8 camera sender and a dedicated video
/// receiver. Credentials remain scoped to the existing audio transport.
public struct MeetVideoOffer: Sendable {
    public let audio: MeetAudioOffer
    public let source: MeetVideoSource
    public let clientConfiguration: Data
    let session: [String]
    let sections: [[String]]
    let video: [String]
    let mids: [String]
    struct Codec: Sendable, Equatable {
        let payload: UInt64
        let name: String
        let apt: UInt64?
    }

    let codecs: [Codec]

    public init(sdp: String, srtpSuite: MeetAudioOffer.SRTPSuite = .aeadAES256GCM) throws {
        let layout = try Self.layout(sdp)
        session = layout.session
        sections = layout.sections
        mids = layout.mids
        let videos = sections.filter { $0[0].hasPrefix("m=video ") }
        video = videos[0]
        guard video.contains("a=sendrecv"), videos[1].contains("a=recvonly"),
              !videos[1].contains(where: { $0.hasPrefix("a=ssrc:") }) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let audioSections = sections.filter { !$0[0].hasPrefix("m=video ") }
        let audioMids = try audioSections.map { try MeetAudioOffer.single("a=mid:", $0) }
        let baseSession = session
            .map {
                $0.hasPrefix("a=group:BUNDLE ") ? "a=group:BUNDLE " + audioMids.joined(separator: " ") : $0
            }
        audio = try MeetAudioOffer(
            sdp: (baseSession + audioSections.flatMap(\.self)).joined(separator: "\r\n") + "\r\n",
            srtpSuite: srtpSuite,
            collections: true,
            streamControl: true
        )
        for section in videos {
            for prefix in ["a=ice-ufrag:", "a=ice-pwd:", "a=fingerprint:", "a=setup:"] {
                let scoped = section.contains(where: { $0.hasPrefix(prefix) }) ? section : session
                guard try MeetAudioOffer.single(prefix, scoped) == MeetAudioOffer.single(prefix, audio.lines)
                else {
                    throw MeetCallWire.WireError.malformedResponse
                }
            }
        }
        source = try Self.sender(video)
        codecs = try Self.videoCodecs(video)
        guard try Self.videoCodecs(videos[1]) == codecs else {
            throw MeetCallWire.WireError.malformedResponse
        }
        clientConfiguration = audio.clientConfiguration + Self.configuration(video: video, codecs: codecs)
    }

    private struct Layout {
        let session: [String]
        let sections: [[String]]
        let mids: [String]
    }

    private static func layout(_ sdp: String) throws -> Layout {
        guard sdp.utf8.count < 100_000,
              !sdp.contains("\0") else { throw MeetCallWire.WireError.malformedResponse }
        let all = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let starts = all.indices.filter { all[$0].hasPrefix("m=") }
        guard starts.count == 4,
              let first = starts.first else { throw MeetCallWire.WireError.malformedResponse }
        let session = Array(all[..<first])
        let sections = starts.enumerated().map { index, start in
            Array(all[start ..< (index + 1 < starts.count ? starts[index + 1] : all.count)])
        }
        guard sections[0][0].hasPrefix("m=audio "),
              sections.filter({ $0[0].hasPrefix("m=video ") }).count == 2,
              sections.filter({ $0[0].hasPrefix("m=application ") }).count == 1 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let mids = try sections.map { try MeetAudioOffer.single("a=mid:", $0) }
        guard Set(mids).count == 4, mids.allSatisfy(MeetAudioOffer.atom),
              try MeetAudioOffer.single("a=group:BUNDLE ", session).split(separator: " ")
              .map(String.init) == mids else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return Layout(session: session, sections: sections, mids: mids)
    }

    private static func configuration(video: [String], codecs: [Codec]) -> Data {
        var configuration = Data()
        for codec in codecs {
            var value = MeetProto.number(1, codec.payload) + MeetProto.string(2, codec.name)
                + MeetProto.number(3, 2) + MeetProto.number(4, 90000) + MeetProto.number(5, 1)
            if let apt = codec.apt {
                value += MeetProto.bytes(
                    6,
                    MeetProto.string(1, "apt") + MeetProto.string(2, String(apt))
                )
            }
            configuration += MeetProto.bytes(3, value)
        }
        for line in video where line.hasPrefix("a=extmap:") {
            let parts = line.dropFirst(9).split(separator: " ")
            guard parts.count == 2, let id = UInt64(parts[0]), (1 ... 255).contains(id),
                  MeetAudioOffer.atom(String(parts[1])) else { continue }
            configuration += MeetProto.bytes(
                4,
                MeetProto.number(1, id) + MeetProto.string(2, String(parts[1]))
                    + MeetProto.number(3, 2) + MeetProto.number(4, 1)
            )
        }
        return configuration
    }

    private static func videoCodecs(_ lines: [String]) throws -> [Codec] {
        var result: [Codec] = []
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let parts = line.dropFirst(9).split(separator: " ")
            guard parts.count == 2, let payload = UInt64(parts[0]),
                  payload <= 127 else { throw MeetCallWire.WireError.malformedResponse }
            let encoding = parts[1].split(separator: "/")
            guard encoding.count == 2, encoding[1] == "90000",
                  ["vp8", "rtx"].contains(encoding[0].lowercased()) else {
                throw MeetCallWire.WireError.malformedResponse
            }
            let name = String(encoding[0])
            let apt: UInt64?
            if name.lowercased() == "rtx" {
                apt = try UInt64(MeetAudioOffer.single("a=fmtp:\(payload) apt=", lines))
                guard apt != nil else { throw MeetCallWire.WireError.malformedResponse }
            } else {
                apt = nil
            }
            result.append(Codec(payload: payload, name: name, apt: apt))
        }
        guard result.count <= 2, result.filter({ $0.name.lowercased() == "vp8" }).count == 1,
              Set(result.map(\.payload)).count == result.count,
              result
              .allSatisfy({
                  $0.apt == nil || $0.apt == result.first(where: { $0.name.lowercased() == "vp8" })?.payload
              })
        else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let payloads = lines[0].split(separator: " ").dropFirst(3).compactMap { UInt64($0) }
        guard Set(payloads) == Set(result.map(\.payload))
        else { throw MeetCallWire.WireError.malformedResponse }
        return result
    }

    private static func sender(_ lines: [String]) throws -> MeetVideoSource {
        var sources = Set<UInt32>()
        for line in lines where line.hasPrefix("a=ssrc:") {
            guard let token = line.dropFirst(7).split(separator: " ").first,
                  let value = UInt32(token), value > 0 else {
                throw MeetCallWire.WireError.malformedResponse
            }
            sources.insert(value)
        }
        let groups = lines.filter { $0.hasPrefix("a=ssrc-group:") }
        if sources.count == 1, groups.isEmpty,
           let value = sources.first {
            return try MeetVideoSource(primary: value)
        }
        guard groups.count == 1 else { throw MeetCallWire.WireError.malformedResponse }
        let parts = groups[0].dropFirst(13).split(separator: " ")
        guard parts.count == 3, parts[0] == "FID", let first = UInt32(parts[1]),
              let second = UInt32(parts[2]),
              sources == Set([first, second]) else { throw MeetCallWire.WireError.malformedResponse }
        return try MeetVideoSource(primary: first, retransmission: second)
    }
}

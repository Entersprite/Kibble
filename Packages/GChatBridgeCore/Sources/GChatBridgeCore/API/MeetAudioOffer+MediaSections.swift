import Foundation

extension MeetAudioOffer {
    struct MediaSections {
        let session: [String]
        let audio: [String]
        let data: [String]?
    }

    static func mediaSections(_ sdp: String, collections: Bool) throws -> MediaSections {
        let all = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let starts = all.indices.filter { all[$0].hasPrefix("m=") }
        guard starts.count == (collections ? 2 : 1), let first = starts.first,
              all[first].hasPrefix("m=audio ") else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let session = Array(all[..<first])
        let audioEnd = starts.count == 2 ? starts[1] : all.endIndex
        let audio = Array(all[first ..< audioEnd])
        let data = collections ? Array(all[audioEnd...]) : nil
        return MediaSections(session: session, audio: session + audio, data: data)
    }

    static func bundledDataMid(_ sections: MediaSections, audioMid: String) throws -> String? {
        guard let data = sections.data else { return nil }
        guard data.first == "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
              try single("a=sctp-port:", data) == "5000" else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let mid = try single("a=mid:", data)
        guard atom(mid), mid != audioMid,
              try single("a=group:BUNDLE ", sections.session).split(separator: " ")
              == [Substring(audioMid), Substring(mid)] else {
            throw MeetCallWire.WireError.malformedResponse
        }
        // One encoded transport serves both bundled m-lines. Refuse an
        // independent application transport instead of discarding its ICE.
        for prefix in ["a=ice-ufrag:", "a=ice-pwd:", "a=fingerprint:", "a=setup:"] {
            let scoped = data.contains(where: { $0.hasPrefix(prefix) }) ? data : sections.session
            guard try single(prefix, scoped) == single(prefix, sections.audio) else {
                throw MeetCallWire.WireError.malformedResponse
            }
        }
        return mid
    }
}

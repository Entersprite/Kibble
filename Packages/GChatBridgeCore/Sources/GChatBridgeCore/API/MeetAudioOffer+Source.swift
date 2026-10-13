import Foundation

public extension MeetAudioOffer {
    /// The actual native sender's declared track and SSRC, not a browser stream.
    struct Source: Sendable {
        public let streamID: String
        public let ssrc: UInt32
    }

    func audioSource() throws -> Source {
        var ssrcs = Set<UInt32>()
        var tracks = Set<String>()
        for line in lines {
            if line.hasPrefix("a=msid:") {
                try tracks.insert(Self.sourceTrack(String(line.dropFirst(7))))
            } else if line.hasPrefix("a=ssrc:") {
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let ssrc = UInt32(parts[0]), ssrc > 0 else {
                    throw MeetCallWire.WireError.malformedResponse
                }
                ssrcs.insert(ssrc)
                if parts[1].hasPrefix("msid:") {
                    try tracks.insert(Self.sourceTrack(String(parts[1].dropFirst(5))))
                }
            }
        }
        guard ssrcs.count == 1, tracks.count == 1, let ssrc = ssrcs.first, let track = tracks.first else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return Source(streamID: track, ssrc: ssrc)
    }

    private static func sourceTrack(_ value: String) throws -> String {
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts.allSatisfy({ atom(String($0)) && $0.utf8.count <= 128 }) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return String(parts[1])
    }
}

import Foundation

public extension MeetVideoOffer {
    /// Bind only a source obtained from this session's downstream collection.
    /// The remote stream's native track identity is local, never a provider ID.
    func answer(serverConfiguration data: Data, receiving source: MeetVideoSource? = nil) throws -> String {
        let base = try audio.answer(serverConfiguration: data).components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        let start = try base.firstIndex(where: { $0.hasPrefix("m=") }).unwrapVideo()
        let application = try base.firstIndex(where: { $0.hasPrefix("m=application ") }).unwrapVideo()
        let audioLines = Array(base[start ..< application])
        let transport = audioLines.filter {
            ["a=ice-", "a=fingerprint:", "a=setup:", "a=candidate:", "a=end-of-candidates"]
                .contains(where: $0.hasPrefix)
        }
        let accepted = try acceptedCodecs(data)
        let extensions = try acceptedExtensions(data)
        var result = Array(base[..<start])
            .map { $0.hasPrefix("a=group:BUNDLE ") ? "a=group:BUNDLE " + mids.joined(separator: " ") : $0 }
        var videoIndex = 0
        for (index, section) in sections.enumerated() {
            if section[0].hasPrefix("m=audio ") {
                let direction = section.contains("a=recvonly") ? "a=sendonly"
                    : (section.contains("a=inactive") ? "a=inactive" : "a=sendrecv")
                result += audioLines.map { $0 == "a=sendrecv" ? direction : $0 }; continue
            }
            if section[0].hasPrefix("m=application ") {
                result += base[application...]; continue
            }
            result += [
                "m=video 9 UDP/TLS/RTP/SAVPF " + accepted.map { String($0.payload) }.joined(separator: " "),
                "c=IN IP4 0.0.0.0",
                "a=mid:\(mids[index])",
                videoIndex == 0 ? "a=recvonly" : "a=sendonly",
                "a=rtcp-mux",
                "a=rtcp-rsize"
            ]
            result += transport
            result += Self.codecLines(accepted, section: section)
            result += extensions.filter { section.contains($0) }
            result += Self.sourceLines(videoIndex == 1 ? source : nil)
            videoIndex += 1
        }
        return result.joined(separator: "\r\n") + "\r\n"
    }

    private static func codecLines(_ accepted: [Codec], section: [String]) -> [String] {
        var result: [String] = []
        for codec in accepted {
            result.append("a=rtpmap:\(codec.payload) \(codec.name)/90000")
            if let apt = codec.apt {
                result.append("a=fmtp:\(codec.payload) apt=\(apt)")
            } else {
                // Advertise only feedback also offered by the native peer.
                for feedback in ["goog-remb", "transport-cc", "ccm fir", "nack"] {
                    let line = "a=rtcp-fb:\(codec.payload) \(feedback)"
                    if section.contains(line) {
                        result.append(line)
                    }
                }
            }
        }

        return result
    }

    private static func sourceLines(_ source: MeetVideoSource?) -> [String] {
        var result: [String] = []
        if let source {
            result.append("a=msid:kibble-remote video")
            for value in source.values {
                result += [
                    "a=ssrc:\(value) cname:kibble-remote",
                    "a=ssrc:\(value) msid:kibble-remote video"
                ]
            }
            if let retransmission = source.retransmission {
                result.append("a=ssrc-group:FID \(source.primary) \(retransmission)")
            }
        }
        return result
    }

    private func acceptedCodecs(_ data: Data) throws -> [Codec] {
        var accepted: [Codec] = []
        for entry in ProtoFieldScan.payloads(ofField: 4, in: data) {
            guard try MeetProto.value(3, entry) == 2 else { continue }
            let payload = try MeetProto.value(1, entry)
            guard let codec = codecs.first(where: { $0.payload == payload }),
                  try MeetProto.text(2, entry).lowercased() == codec.name.lowercased(),
                  try MeetProto.value(4, entry) == 90000,
                  try MeetProto.value(5, entry) == 1 else { continue }
            // Alternative packetizations use different payloads. This native
            // peer offers standard VP8 only.
            if ProtoFieldScan.fields(in: entry).fields.contains(where: { $0.number == 7 }),
               try MeetProto.value(7, entry) != 0 {
                continue
            }
            let parameters = ProtoFieldScan.payloads(ofField: 6, in: entry)
            if let apt = codec.apt {
                guard parameters.count == 1, try MeetProto.text(1, parameters[0]) == "apt",
                      try MeetProto.text(2, parameters[0]) == String(apt)
                else { throw MeetCallWire.WireError.malformedResponse }
            } else if !parameters.isEmpty {
                throw MeetCallWire.WireError.malformedResponse
            }
            guard !accepted.contains(where: { $0.payload == payload })
            else { throw MeetCallWire.WireError.malformedResponse }
            accepted.append(codec)
        }
        guard accepted.contains(where: { $0.name.lowercased() == "vp8" }),
              accepted
              .allSatisfy({ codec in
                  codec.apt == nil || accepted.contains(where: { $0.payload == codec.apt }) }) else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return accepted
    }

    private func acceptedExtensions(_ data: Data) throws -> [String] {
        try ProtoFieldScan.payloads(ofField: 5, in: data).compactMap { entry in
            guard try MeetProto.value(3, entry) == 2, try MeetProto.value(4, entry) == 1 else { return nil }
            let id = try MeetProto.value(1, entry), uri = try MeetProto.text(2, entry)
            guard (1 ... 255).contains(id),
                  MeetAudioOffer.atom(uri) else { throw MeetCallWire.WireError.malformedResponse }
            let line = "a=extmap:\(id) \(uri)"
            return video.contains(line) ? line : nil
        }
    }
}

private extension Optional {
    func unwrapVideo() throws -> Wrapped {
        guard let value = self else { throw MeetCallWire.WireError.malformedResponse }
        return value
    }
}

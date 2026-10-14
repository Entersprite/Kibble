import Foundation

/// Negotiated SDK transport values become fixed categories, never arbitrary text.
struct NativeTransportStatistics: Sendable {
    private var streamCount = 0
    private var ciphers = Set<Cipher>()
    private var versions = Set<Version>()

    private enum Cipher: String, Sendable {
        case matching = "matches advertised AES-256-GCM"
        case different = "different supported cipher"
        case unavailable
    }

    private enum Version: String, Sendable {
        case dtls12 = "DTLS 1.2"
        case dtls10 = "DTLS 1.0"
        case tls13 = "TLS 1.3"
        case unavailable
    }

    mutating func add(_ values: [String: NSObject]) {
        streamCount += 1
        switch values["srtpCipher"] as? String {
        case "SRTP_AEAD_AES_256_GCM": ciphers.insert(.matching)
        case "SRTP_AEAD_AES_128_GCM", "SRTP_AES128_CM_HMAC_SHA1_80", "SRTP_AES128_CM_HMAC_SHA1_32":
            ciphers.insert(.different)
        default: ciphers.insert(.unavailable)
        }
        switch values["tlsVersion"] as? String {
        case "FEFD": versions.insert(.dtls12)
        case "FEFF": versions.insert(.dtls10)
        case "0304": versions.insert(.tls13)
        default: versions.insert(.unavailable)
        }
    }

    func report() -> [String] {
        let cipher = ciphers
            .count > 1 ? "mixed transport results" : (ciphers.first?.rawValue ?? "unavailable")
        let version = versions
            .count > 1 ? "mixed transport results" : (versions.first?.rawValue ?? "unavailable")
        return [
            "Native media transport records: \(streamCount)",
            "Native media negotiated SRTP: \(cipher)",
            "Native media negotiated TLS version: \(version)"
        ]
    }
}

/// Uses only the local audio offer and local audio RTP statistics; identifiers
/// are reduced to match counts before a sampled result leaves the callback.
struct NativeAudioSourceMatch: Sendable {
    private var streamCount = 0
    private var matched = 0
    private var mismatched = 0

    mutating func add(_ raw: NSObject?, expected: UInt32?) {
        streamCount += 1
        guard let expected, let number = NativeDiagnosticNumber.value(raw, integer: true),
              number > 0, number <= Double(UInt32.max) else { return }
        if UInt32(number) == expected {
            matched += 1
        } else {
            mismatched += 1
        }
    }

    func report() -> [String] {
        let label = if mismatched > 0 {
            "mismatch"
        } else if streamCount > 0, matched == streamCount {
            "matches"
        } else {
            "unavailable"
        }
        return ["Native audio outbound source matches local offer: \(label)"]
    }

    static func localAudioSSRC(_ sdp: String?) -> UInt32? {
        guard let sdp, sdp.utf8.count < 100_000, !sdp.contains("\0") else { return nil }
        var inAudio = false
        var sections = 0
        var sources = Set<UInt32>()
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=") {
                inAudio = line.hasPrefix("m=audio ")
                if inAudio {
                    sections += 1
                }
            } else if inAudio, line.hasPrefix("a=ssrc:") {
                let token = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard token.count == 2, let value = UInt32(token[0]), value > 0 else { return nil }
                sources.insert(value)
                guard sources.count <= 1 else { return nil }
            }
        }
        return sections == 1 && sources.count == 1 ? sources.first : nil
    }
}

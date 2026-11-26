import Foundation

/// Shareable dial-in details from the resolved meeting space.
public struct MeetDialIn: Sendable, Equatable {
    public let phoneNumber: String
    public let pin: String
    public let region: String?

    static func rows(in space: Data) -> [Self] {
        let rows = ProtoFieldScan.payloads(ofField: 5, in: space)
        var seen = Set<String>()
        return rows.prefix(128).compactMap { raw in
            guard let row = parse(raw) else { return nil }
            let digits = row.phoneNumber.utf8.filter(isDigit)
            let key = "\(String(decoding: digits, as: UTF8.self))/\(row.pin)/\(row.region ?? "")"
            return seen.insert(key).inserted ? row : nil
        }
    }

    static func phoneDirectory(in space: Data, meetingURL: URL) -> URL? {
        guard let shared = try? MeetProto.payload(8, space),
              let pin = try? MeetProto.text(1, shared), normalizedPIN(pin) != nil,
              let meeting = try? MeetJoinLink(meetingURL) else { return nil }
        return URL(string: "https://tel.meet/\(meeting.code)?hs=5")
    }

    private static func parse(_ row: Data) -> Self? {
        guard row.count <= 512,
              let number = try? MeetProto.text(5, row),
              let pin = try? MeetProto.text(2, row) else { return nil }
        let phoneNumber = number.trimmingCharacters(in: .whitespaces)
        let digits = phoneNumber.utf8.dropFirst()
        let separators = " -().".utf8
        guard phoneNumber.hasPrefix("+"), phoneNumber.utf8.count <= 40,
              (7 ... 15).contains(digits.filter(isDigit).count),
              digits.allSatisfy({ isDigit($0) || separators.contains($0) }),
              let pinDigits = normalizedPIN(pin)
        else { return nil }
        let region: String? = (try? MeetProto.text(3, row)).flatMap { rawRegion in
            let value = rawRegion.uppercased()
            return value.utf8.count == 2 && value.utf8.allSatisfy { (65 ... 90).contains($0) } ? value : nil
        }
        return Self(phoneNumber: phoneNumber, pin: pinDigits, region: region)
    }

    private static func normalizedPIN(_ pin: String) -> String? {
        guard pin.utf8.count <= 24, pin.utf8.allSatisfy({ isDigit($0) || $0 == 32 }) else { return nil }
        let pinDigits = pin.replacingOccurrences(of: " ", with: "")
        return (1 ... 16).contains(pinDigits.utf8.count) ? pinDigits : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }
}

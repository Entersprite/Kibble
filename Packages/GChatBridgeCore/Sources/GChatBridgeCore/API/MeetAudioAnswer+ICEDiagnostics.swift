import Foundation

extension MeetAudioOffer {
    /// Report only fixed field/shape labels and bounded byte lengths. This
    /// diagnostic never retains the credential or prints an arbitrary byte.
    public static func iceDiagnostics(serverConfiguration data: Data) -> [String] {
        guard data.count <= 500_000, let stun = try? MeetProto.payload(2, data),
              (try? MeetProto.validate(stun)) != nil else {
            return ["Native ICE diagnostic: malformed STUN configuration"]
        }
        return [
            credentialDiagnostic(stun, field: 3, label: "ufrag", minimum: 4),
            credentialDiagnostic(stun, field: 4, label: "password", minimum: 22)
        ]
    }

    private static func credentialDiagnostic(
        _ data: Data,
        field: Int,
        label: String,
        minimum: Int
    ) -> String {
        let prefix = "Native ICE " + label + ": "
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == field }
        guard !fields.isEmpty else { return prefix + "missing field" }
        guard fields.count == 1 else { return prefix + "duplicate field" }
        guard let bytes = try? MeetProto.payload(field, data) else { return prefix + "wrong field type" }
        let length = bytes.count <= 256 ? String(bytes.count) : ">256"
        guard let value = String(data: bytes, encoding: .utf8) else {
            return prefix + "bytes " + length + "; invalid UTF-8"
        }
        return prefix + "bytes " + length + "; alphabet " + credentialAlphabet(value)
            + "; padding " + credentialPadding(value)
            + "; supported " + (validRemoteCredential(value, minimum: minimum) ? "yes" : "no")
    }

    private static func credentialAlphabet(_ value: String) -> String {
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
        }
        if value.utf8.allSatisfy({ alphanumeric($0) || [43, 47, 61].contains($0) }) {
            return "Base64"
        }
        if value.utf8.allSatisfy({ alphanumeric($0) || [45, 95, 61].contains($0) }) {
            return "URL-safe Base64"
        }
        if value.utf8.allSatisfy({ (33 ... 126).contains($0) }) {
            return "other ASCII"
        }
        return "whitespace/control or non-ASCII"
    }

    private static func credentialPadding(_ value: String) -> String {
        guard value.utf8.contains(61) else { return "none" }
        let tail = value.utf8.reversed().prefix { $0 == 61 }.count
        guard !value.dropLast(tail).utf8.contains(61) else { return "interior" }
        switch tail {
        case 1: return "terminal 1"
        case 2: return "terminal 2"
        default: return "invalid"
        }
    }
}

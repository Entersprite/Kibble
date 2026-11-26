import Foundation
import LocalBridgeBackend

/// Keep unsignaled audio routable with the pinned M150 transport. It applies
/// payload-type demuxing once per MID, even when those MIDs share one transport.
/// Video's disabled fallback must not overwrite audio's enabled fallback.
enum NativeCallSDP {
    static func audioMIDLast(_ sdp: String) throws -> String {
        let lines = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var audio = false
        var audioMIDs: [String] = []
        for line in lines {
            if line.hasPrefix("m=") {
                audio = line.hasPrefix("m=audio ")
            }
            if audio, line.hasPrefix("a=mid:") {
                audioMIDs.append(String(line.dropFirst(6)))
            }
        }
        let replacement = "kibble-audio"
        let mids = lines.filter { $0.hasPrefix("a=mid:") }.map { String($0.dropFirst(6)) }
        guard audioMIDs.count == 1, let original = audioMIDs.first,
              Set(mids).count == mids.count,
              mids.filter({ $0 != original }).allSatisfy({ $0 < replacement }) else {
            throw CallMediaError.negotiationFailed
        }
        // Preserve media order and BUNDLE membership. Only the opaque local MID
        // changes, before its first installation; subsequent offers retain it.
        return lines.map { line in
            if line == "a=mid:" + original {
                return "a=mid:" + replacement
            }
            if line.hasPrefix("a=group:BUNDLE ") {
                return "a=group:BUNDLE " + line.dropFirst(15).split(separator: " ")
                    .map { $0 == original ? replacement : String($0) }.joined(separator: " ")
            }
            return line
        }.joined(separator: "\r\n") + "\r\n"
    }
}

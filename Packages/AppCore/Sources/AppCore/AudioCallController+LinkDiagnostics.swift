import Foundation

/// Structural counts and fixed categories only. Never retain or export any URL
/// component text, including query names, fragments, account hints or nicknames.
enum MeetingLinkDiagnosticShape {
    static func lines(_ url: URL, supportedHosts: Set<String>) -> [String] {
        guard url.absoluteString.utf8.count <= 2048 else {
            return ["Meeting link shape: over size limit"]
        }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ["Meeting link shape: unreadable"]
        }
        let scheme = value.scheme?.lowercased() == "https" ? "https" : "other"
        let host = value.host.map { supportedHosts.contains($0.lowercased()) } ?? false
        let credentials = value.user != nil || value.password != nil
        let port = value.port == nil ? "default" : value.port == 443 ? "https" : "other"
        let path = value.percentEncodedPath
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        let groups = segments.last?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        let lowercase = segments.last?.utf8.allSatisfy { (97 ... 122).contains($0) || $0 == 45 } ?? false
        return [
            "Meeting link shape: scheme=\(scheme); advertised host=\(host); "
                + "credentials=\(credentials); port=\(port)",
            "Meeting link path: segments=\(segments.count); lengths=\(lengths(segments)); "
                + "trailing slash=\(path.hasSuffix("/")); bytes=\(path.utf8.count)",
            "Meeting link last segment: groups=\(lengths(groups)); lowercase ASCII=\(lowercase)",
            "Meeting link decorations: percent escapes=\(path.contains("%")); "
                + "query=\(value.query != nil); fragment=\(value.fragment != nil)"
        ]
    }

    private static func lengths(_ values: [Substring]) -> String {
        values.prefix(8).map { String($0.utf8.count) }
            .joined(separator: ",") + (values.count > 8 ? ",more" : "")
    }
}

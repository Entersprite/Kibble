import Foundation
import GChatBridgeCore

/// The file download again, asked the ways a browser differs from the app.
/// Chat on the web downloads a file by navigating a new tab to it, and
/// `chat.usercontent.google.com` serves that tab where it answers this client
/// 403 with the same cookies (`findings.md` §52.1, §52.4). Each rung adds
/// one difference, so the first that succeeds names it. A cookie the browser
/// holds for that host alone is not tested: the capture never kept one.
extension APIProbeReport {
    static let downloadLadder: [(label: String, style: AttachmentFetch.RequestStyle)] = [
        ("1 navigation headers", AttachmentFetch.RequestStyle(navigation: true)),
        ("2 + Referer", AttachmentFetch.RequestStyle(navigation: true, referer: true)),
        (
            "3 + no content_type",
            AttachmentFetch.RequestStyle(navigation: true, referer: true, sendsContentType: false)
        ),
        ("4 app request, no content_type", AttachmentFetch.RequestStyle(sendsContentType: false))
    ]

    /// The app's own endpoints only: §52.1 showed the bare path answers the
    /// same, and every rung is a request against the live account.
    static func appendDownloadLadderSection(
        upload: ProbedUpload?,
        fetch: AttachmentFetch?,
        lines: inout [String]
    ) async {
        lines.append("attachment download ladder (file, app endpoints, browser differences):")
        guard let upload, let fetch else {
            lines.append("  no file upload on this page - post one in this conversation and rerun")
            return
        }
        for rung in downloadLadder {
            let outcome: Result<FetchedAttachment, AttachmentFetchFailure>
            do {
                outcome = try await .success(fetch.fetch(
                    token: upload.token, contentType: upload.contentType, variant: .file, style: rung.style
                ))
            } catch {
                outcome = .failure(error)
            }
            lines.append(contentsOf: attachmentDownloadLines(label: rung.label, outcome: outcome))
        }
    }

    // MARK: - Address and refusal shapes

    /// Each hop's address as host, masked path and query names, and a
    /// refusal's type, size and header names, so a run can be compared with
    /// the browser's download address read out of `brave://downloads`
    /// (`findings.md` §52.5). Printed only when a hop recorded any of it.
    static func addressAndRefusalLines(
        _ outcome: Result<FetchedAttachment, AttachmentFetchFailure>
    ) -> [String] {
        let hops: [AttachmentHop]
        var refusal: AttachmentFetchFailure.Refusal?
        switch outcome {
        case let .success(fetched): hops = fetched.hops
        case let .failure(failure):
            hops = failure.hops
            refusal = failure.refusal
        }
        var lines: [String] = []
        if hops.contains(where: { !$0.pathSegments.isEmpty || !$0.queryNames.isEmpty }) {
            lines.append("    addresses: " + hops.map(addressShape).joined(separator: " → "))
        }
        if let refusal {
            let names = refusal.headerNames.map { isHeaderName($0) ? $0 : "h\($0.count)" }
            let type = refusal.contentType.map(contentTypeKey) ?? "none"
            let headers = names.isEmpty ? "-" : names.joined(separator: ",")
            lines.append("    refusal: content type \(type), \(refusal.bodyBytes) bytes, headers \(headers)")
        }
        return lines
    }

    private static func addressShape(_ hop: AttachmentHop) -> String {
        let path = hop.pathSegments.map { isPrintableSegment($0) ? $0 : "…" }.joined(separator: "/")
        let names = hop.queryNames.map { ProjectorConfigShape.isIdentifier($0) ? $0 : "?" }
        return "\(renderHost(hop.host)) /\(path) ?\(names.isEmpty ? "-" : names.joined(separator: ","))"
    }

    /// Lowercase letters and underscores (`get_attachment_url`), or a number
    /// of at most two digits (the account index). Tokens here are mixed case
    /// and carry digits; a lowercase-only one would print, the same exposure
    /// `ProjectorConfigShape`'s plain-word rule accepts.
    private static func isPrintableSegment(_ segment: String) -> Bool {
        if segment.count <= 2, segment.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return true
        }
        return !segment.isEmpty && segment.count <= 30
            && segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") }
    }

    private static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

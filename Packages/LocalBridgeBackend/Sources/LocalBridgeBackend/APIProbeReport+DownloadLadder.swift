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
}

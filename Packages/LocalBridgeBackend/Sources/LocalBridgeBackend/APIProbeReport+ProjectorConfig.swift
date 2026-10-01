import Foundation
import GChatBridgeCore

/// `get_projector_config`: what Chat on the web asks for when a file is
/// opened (`findings.md` §52.2), where `get_attachment_url?url_type=DOWNLOAD_URL`
/// is refused by `chat.usercontent.google.com` (§52.1). The answer is printed
/// only as `ProjectorConfigShape`'s masked shape.
extension APIProbeReport {
    static func appendProjectorConfigSection(
        upload: ProbedUpload?,
        fetches: [(label: String, fetch: AttachmentFetch)],
        lines: inout [String]
    ) async {
        lines.append("attachment viewer (get_projector_config, first non-image upload):")
        guard let upload else {
            lines.append("  no file upload on this page - post one in this conversation and rerun")
            return
        }
        for (label, fetch) in fetches {
            let outcome: Result<FetchedAttachment, AttachmentFetchFailure>
            do {
                outcome = try await .success(fetch.projectorConfig(
                    token: upload.token, contentType: upload.contentType
                ))
            } catch {
                outcome = .failure(error)
            }
            lines.append(contentsOf: projectorConfigLines(label: label, outcome: outcome))
        }
    }

    static func projectorConfigLines(
        label: String,
        outcome: Result<FetchedAttachment, AttachmentFetchFailure>
    ) -> [String] {
        var lines = hopLines(label: label, outcome: outcome) { fetched in
            "content type \(fetched.contentType.map(contentTypeKey) ?? "none"), \(fetched.body.count) bytes"
        }
        if case let .success(fetched) = outcome {
            lines.append("    shape: \(ProjectorConfigShape.render(fetched.body))")
        }
        return lines
    }
}

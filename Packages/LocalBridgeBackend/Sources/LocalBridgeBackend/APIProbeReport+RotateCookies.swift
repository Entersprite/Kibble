import Foundation
import GChatBridgeCore

/// The file download once more, after `RotateCookies` has set the
/// `.google.com` `*PSIDTS` pair the login capture lacked (`findings.md`
/// §52.7). If this rung downloads where rungs 1-4 were refused, the pair is
/// what `chat.usercontent.google.com` wanted.
///
/// **A throwaway copy of the session, on the owner's decision.** The
/// bootstrap's credentials write every rotation back to the Keychain, so the
/// rung copies them into a `SessionCredentials` that saves nothing. Whatever
/// the accounts host sets lives for this one rung and is gone with it; the
/// app's stored session is exactly what it was.
extension APIProbeReport {
    struct RotationRung {
        let transport: any HTTPTransport
        let endpoints: ChatEndpoints
        /// The bootstrap's. Only ever copied from, never sent through.
        let credentials: SessionCredentials
        let xsrfToken: String?
    }

    static let rotatedNames = ["__Secure-1PSIDTS", "__Secure-3PSIDTS"]

    static func appendRotatedDownloadSection(
        upload: ProbedUpload?,
        rung: RotationRung,
        lines: inout [String]
    ) async {
        lines
            .append(
                "attachment download after RotateCookies (a throwaway copy of the session; nothing is saved):"
            )
        guard let upload, let snapshot = await rung.credentials.snapshot else {
            lines.append("  no file upload on this page - post one in this conversation and rerun")
            return
        }
        let copy = SessionCredentials(snapshot)
        do {
            let outcome = try await RotateCookies(
                transport: rung.transport, userAgent: rung.endpoints.userAgent, credentials: copy
            ).send()
            let names = outcome.setCookieNames.map(cookieNameShape)
            let set = names.isEmpty ? "nothing" : names.joined(separator: ",")
            lines.append("  RotateCookies: \(outcome.status), set \(set)")
        } catch {
            lines.append("  RotateCookies FAILED: \(safeDescription(of: error))")
            return
        }
        let held = await copy.snapshot
        lines.append("  copy now holds: " + rotatedNames.map { name in
            "\(name) \(held?[name] == nil ? "no" : "yes")"
        }.joined(separator: ", "))

        let fetch = AttachmentFetch(
            transport: rung.transport, endpoints: rung.endpoints, credentials: copy, xsrfToken: rung.xsrfToken
        )
        let outcome: Result<FetchedAttachment, AttachmentFetchFailure>
        do {
            outcome = try await .success(fetch.fetch(
                token: upload.token, contentType: upload.contentType, variant: .file
            ))
        } catch {
            outcome = .failure(error)
        }
        lines.append(contentsOf: attachmentDownloadLines(
            label: "5 app request, rotated copy",
            outcome: outcome
        ))
    }

    /// A cookie's name prints when it is made only of the characters Google's
    /// own names use; anything else is a length.
    static func cookieNameShape(_ name: String) -> String {
        let plain = !name.isEmpty && name.count <= 40
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return plain ? name : "c\(name.count)"
    }
}

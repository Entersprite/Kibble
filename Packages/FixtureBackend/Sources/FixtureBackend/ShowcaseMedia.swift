import ChatKit
import Foundation

/// Original sample artwork/documents bundled with the demo, never fetched from the network.
enum ShowcaseMedia {
    static let attachments: [String: String] = [
        "showcase/studio-board": "studio-board.png",
        "showcase/weekend-poster": "weekend-poster.png",
        "showcase/creative-brief": "creative-brief.pdf",
        "showcase/launch-checklist": "launch-checklist.txt"
    ]
    static let images: [String: String] = [
        "/showcase/launch-preview.png": "launch-preview.png",
        "/showcase/studio-board.png": "studio-board.png"
    ]

    static func attachmentData(_ attachment: Attachment) throws -> Data? {
        guard let name = attachments[attachment.id] else { return nil }
        return try data(named: name)
    }

    static func imageData(_ url: URL) throws -> Data? {
        guard let name = images[url.path] else { return nil }
        return try data(named: name)
    }

    static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw ChatError.unknown("The bundled demo file is unavailable.")
        }
        return try Data(contentsOf: url)
    }
}

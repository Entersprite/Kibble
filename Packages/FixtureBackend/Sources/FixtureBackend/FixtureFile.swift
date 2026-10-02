import ChatKit
import Foundation

/// The bytes the fixture backend downloads. A picture is `FixtureImage.png`;
/// any other upload is one fixed, tiny PDF, so a download is deterministic
/// and a Debug run can open what it saved.
enum FixtureFile {
    static func bytes(for attachment: Attachment) -> Data {
        attachment.isImage ? FixtureImage.png : pdf
    }

    static let pdf = Data("""
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
    trailer << /Root 1 0 R >>
    %%EOF

    """.utf8)
}

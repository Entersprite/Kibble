import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessageEmbedMappingTests {
    @Test func documentAndVideoMetadataUseTheExistingLinkAndScopedImagePath() {
        var drive = Annotation()
        drive.driveMetadata.id = "document-id"
        drive.driveMetadata.title = "Project plan"
        drive.driveMetadata.thumbnailURL = "https://images.example.test/document.png"
        drive.driveMetadata.thumbnailWidth = 400
        drive.driveMetadata.thumbnailHeight = 300
        var video = Annotation()
        video.youtubeMetadata.id = "abcdefghijk"
        let links = MessageEmbedMapping.links([drive, video], alongside: [])
        #expect(links.count == 2)
        #expect(links[0].preview?.presentation == "document")
        #expect(links[0].preview?.imageWidth == 400)
        #expect(links[1].preview?.playbackURL?
            .absoluteString == "https://www.youtube-nocookie.com/embed/abcdefghijk")
        let enriched = MessageEmbedMapping.links([video], alongside: [MessageLink(
            url: links[1].url, preview: LinkPreview(title: "A video title")
        )])
        #expect(enriched.count == 1)
        #expect(enriched[0].preview?.title == "A video title")
        #expect(enriched[0].preview?.presentation == "video")
        drive.driveMetadata.shouldNotRender = true
        video.youtubeMetadata.id = "../../invalid"
        #expect(MessageEmbedMapping.links([drive, video], alongside: []).isEmpty)
    }
}

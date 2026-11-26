import ChatKit
import Foundation
import GChatBridgeCore

enum MessageEmbedMapping {
    static func links(_ annotations: [Annotation], alongside links: [MessageLink]) -> [MessageLink] {
        var result = links
        for annotation in annotations {
            guard annotation.chipRenderType != .doNotRender else { continue }
            let embed: MessageLink? = switch annotation.metadata {
            case let .driveMetadata(metadata)?: document(metadata)
            case let .youtubeMetadata(metadata)?: video(metadata)
            default: nil
            }
            guard let embed else { continue }
            if let index = result
                .firstIndex(where: {
                    $0.url == embed
                        .url ||
                        (embed.preview?.presentation == "video" && videoID($0.url) == videoID(embed.url))
                }) {
                var preview = result[index].preview ?? embed.preview
                preview?.presentation = embed.preview?.presentation
                preview?.playbackURL = embed.preview?.playbackURL
                if preview?.imageURL == nil {
                    preview?.imageURL = embed.preview?.imageURL
                }
                result[index].preview = preview
            } else {
                result.append(embed)
            }
        }
        return result
    }

    private static func videoID(_ url: URL) -> String? {
        let host = url.host?.lowercased()
        if host == "youtu.be" {
            return url.pathComponents.dropFirst().first
        }
        guard ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host ?? "")
        else { return nil }
        if url
            .path ==
            "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "v" }?.value
        }
        let parts = url.pathComponents.dropFirst()
        guard let kind = parts.first, ["embed", "shorts", "live"].contains(kind) else { return nil }
        return parts.dropFirst().first
    }

    private static func document(_ metadata: DriveMetadata) -> MessageLink? {
        guard !metadata.shouldNotRender else { return nil }
        let direct = ChannelEventMapping.webURL(metadata.urlFragment)
            ?? ChannelEventMapping.webURL(metadata.embedURL.resourceURL)
        var components = URLComponents(string: "https://drive.google.com/open")
        components?.queryItems = [URLQueryItem(name: "id", value: metadata.id)]
        guard let url = direct ?? (!metadata.id.isEmpty && !metadata.encryptedDocID ? components?.url : nil)
        else { return nil }
        let thumbnail = ChannelEventMapping.webURL(metadata.thumbnailURL)
            .flatMap { $0.scheme == "https" ? $0 : nil }
        return MessageLink(url: url, preview: LinkPreview(
            title: metadata.title.isEmpty ? "Document" : metadata.title,
            imageURL: thumbnail,
            imageWidth: metadata.thumbnailWidth > 0 ? Int(metadata.thumbnailWidth) : nil,
            imageHeight: metadata.thumbnailHeight > 0 ? Int(metadata.thumbnailHeight) : nil,
            domain: url.host, presentation: "document"
        ))
    }

    private static func video(_ metadata: YoutubeMetadata) -> MessageLink? {
        let id = metadata.id
        guard id.utf8.count == 11, id.utf8.allSatisfy({
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57)
                .contains($0) || $0 == 45 || $0 == 95
        }), let url = URL(string: "https://www.youtube.com/watch?v=\(id)"),
        let player = URL(string: "https://www.youtube-nocookie.com/embed/\(id)") else { return nil }
        return MessageLink(url: url, preview: LinkPreview(
            title: "Video", domain: url.host, presentation: "video", playbackURL: player
        ))
    }
}

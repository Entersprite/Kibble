import ChatKit
import Foundation
import GChatBridgeCore

/// What link previews and app cards look like on the wire (links spec §2).
/// **Counts and closed vocabularies only:** no URL, title, text, host or
/// identifier is ever kept here, so nothing in this type can leak one.
struct LinkCardShapes: Equatable {
    var conversations = 0
    var failedConversations = 0
    var messages = 0
    var urlAnnotationsByType = 0
    var urlMetadata = 0
    /// Raw `url_source` values as strings, or `absent`.
    var urlSources: [String: Int] = [:]
    var spanAbsent = 0
    var spanZero = 0
    var spanInRange = 0
    var spanOutOfRange = 0
    /// In range, and the spanned text is exactly one detected URL.
    var spanIsURL = 0
    var linkMessagesWithoutURLInText = 0
    var withTitle = 0
    var withSnippet = 0
    var withImage = 0
    var imageHosts: [String: Int] = [:]
    var shouldNotRender: [String: Int] = [:]
    var chipRenderTypes: [String: Int] = [:]
    var neighbours: [String: Int] = [:]
    var withAttachmentsField = 0
    var cardsDecoded = 0
    /// Field 7 found in an attachment's own bytes, whatever the decode did.
    var cardsByteScan = 0
    var cardsWithHeader = 0
    var sections = 0
    var widgetKinds: [String: Int] = [:]
    /// Field numbers in a widget's `unknownFields`: a widget kind the vendored
    /// proto does not name. Numbers only, never a payload.
    var unknownWidgetFields: [String: Int] = [:]
    var clickKinds: [String: Int] = [:]
    var textElements = 0
    var textOriginalOnly = 0
    var textOriginalWithMarkup = 0
    var cardImageHosts: [String: Int] = [:]
    var ownWithURL = 0
    var ownWithURLAnnotated = 0
}

extension APIProbeReport {
    /// One conversation's newest page is too few to find either shape.
    static let linkCardConversationLimit = 20

    static func appendLinkCardSection(
        client: ProtoAPIClient,
        conversations: [Conversation],
        selfUserID: String?,
        lines: inout [String]
    ) async {
        lines.append("")
        lines.append("link and card shapes (counts only):")
        var shapes = LinkCardShapes()
        let recent = conversations
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(linkCardConversationLimit)
        for conversation in recent {
            guard let group = ChannelEventMapping.groupID(for: conversation.id) else {
                shapes.failedConversations += 1
                continue
            }
            do {
                let response: ListTopicsResponse = try await client.call(
                    .listTopics, TopicsRequestLadder.minimumViable(for: group).request
                )
                shapes.conversations += 1
                countLinkCardShapes(response.topics.flatMap(\.replies), selfUserID: selfUserID, into: &shapes)
            } catch {
                shapes.failedConversations += 1
            }
        }
        lines.append(contentsOf: linkCardShapesLines(shapes))
    }

    static func countLinkCardShapes(
        _ messages: [GChatBridgeCore.Message], selfUserID: String?, into shapes: inout LinkCardShapes
    ) {
        for message in messages {
            shapes.messages += 1
            let text = message.textBody
            let hasLink = message.annotations.contains { annotation in
                if case .urlMetadata? = annotation.metadata {
                    return true
                }
                return false
            }
            for annotation in message.annotations {
                countLink(annotation, text: text, into: &shapes)
                countNeighbour(annotation, into: &shapes)
            }
            let textHasURL = !urlRanges(in: text).isEmpty
            if hasLink, !textHasURL {
                shapes.linkMessagesWithoutURLInText += 1
            }
            countCards(message.attachments, into: &shapes)
            if let selfUserID, message.creator.userID.id == selfUserID, textHasURL {
                shapes.ownWithURL += 1
                if hasLink {
                    shapes.ownWithURLAnnotated += 1
                }
            }
        }
    }

    static func linkCardShapesLines(_ shapes: LinkCardShapes) -> [String] {
        let own = shapes.ownWithURL == 0
            ? "  own sends: no own message with a URL found - send one from Kibble and run again"
            : "  own sends with a URL: \(shapes.ownWithURL), "
            + "with a link annotation: \(shapes.ownWithURLAnnotated)"
        return [
            "  conversations scanned: \(shapes.conversations), failed: \(shapes.failedConversations); "
                + "messages: \(shapes.messages)",
            "  URL annotations: by type \(shapes.urlAnnotationsByType), "
                + "with url_metadata \(shapes.urlMetadata); "
                + "url_source: \(named(shapes.urlSources))",
            "  link spans: absent \(shapes.spanAbsent), zero-length \(shapes.spanZero), "
                + "in range \(shapes.spanInRange) (the URL itself \(shapes.spanIsURL)), "
                + "out of range \(shapes.spanOutOfRange)",
            "  messages with a link but no URL in the text: \(shapes.linkMessagesWithoutURLInText)",
            "  previews: title \(shapes.withTitle), snippet \(shapes.withSnippet), image \(shapes.withImage) "
                + "(hosts: \(named(shapes.imageHosts))); "
                + "should_not_render: \(named(shapes.shouldNotRender)); "
                + "chip_render_type: \(named(shapes.chipRenderTypes))",
            "  neighbours: \(named(shapes.neighbours))",
            "  cards: messages with field 15 \(shapes.withAttachmentsField); decoded \(shapes.cardsDecoded), "
                + "field-7 byte scan \(shapes.cardsByteScan); with header \(shapes.cardsWithHeader); "
                + "sections \(shapes.sections)",
            "  widget kinds: \(named(shapes.widgetKinds)); "
                + "unknown widget fields: \(named(shapes.unknownWidgetFields))",
            "  click kinds: \(named(shapes.clickKinds))",
            "  card text: formatted elements \(shapes.textElements), original_text only "
                + "\(shapes.textOriginalOnly) (with markup \(shapes.textOriginalWithMarkup)); "
                + "card image hosts: \(named(shapes.cardImageHosts))",
            own
        ]
    }

    /// `google` for Google's own image hosts, else `other`. Never the host.
    static func hostClass(_ raw: String) -> String {
        guard let host = URL(string: raw)?.host()?.lowercased() else { return "unparseable" }
        let google = ["googleusercontent.com", "ggpht.com", "gstatic.com", "google.com"]
        return google.contains { host == $0 || host.hasSuffix(".\($0)") } ? "google" : "other"
    }

    static func urlRanges(in text: String) -> [NSRange] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func named(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    private static func countLink(
        _ annotation: GChatBridgeCore.Annotation, text: String, into shapes: inout LinkCardShapes
    ) {
        if annotation.hasType, annotation.type == .url {
            shapes.urlAnnotationsByType += 1
        }
        guard case let .urlMetadata(metadata)? = annotation.metadata else { return }
        shapes.urlMetadata += 1
        if metadata.hasURLSource {
            shapes.urlSources[String(metadata.urlSource.rawValue), default: 0] += 1
        } else {
            let raw = ProtoFieldScan.varintValues(ofField: 16, in: metadata.unknownFields.data)
            shapes.urlSources[raw.first.map { String($0) } ?? "absent", default: 0] += 1
        }
        countSpan(annotation, text: text, into: &shapes)
        if !metadata.title.isEmpty {
            shapes.withTitle += 1
        }
        if !metadata.snippet.isEmpty {
            shapes.withSnippet += 1
        }
        if !metadata.imageURL.isEmpty {
            shapes.withImage += 1
            shapes.imageHosts[hostClass(metadata.imageURL), default: 0] += 1
        }
        let hidden = metadata.hasShouldNotRender ? String(metadata.shouldNotRender) : "absent"
        shapes.shouldNotRender[hidden, default: 0] += 1
        if annotation.hasChipRenderType {
            shapes.chipRenderTypes[String(annotation.chipRenderType.rawValue), default: 0] += 1
        }
    }

    private static func countSpan(
        _ annotation: GChatBridgeCore.Annotation, text: String, into shapes: inout LinkCardShapes
    ) {
        guard annotation.hasStartIndex, annotation.hasLength else {
            shapes.spanAbsent += 1
            return
        }
        let start = Int(annotation.startIndex)
        let length = Int(annotation.length)
        if length == 0 {
            shapes.spanZero += 1
        } else if start >= 0, start + length <= text.utf16.count {
            shapes.spanInRange += 1
            if urlRanges(in: text).contains(NSRange(location: start, length: length)) {
                shapes.spanIsURL += 1
            }
        } else {
            shapes.spanOutOfRange += 1
        }
    }

    private static func countNeighbour(
        _ annotation: GChatBridgeCore.Annotation, into shapes: inout LinkCardShapes
    ) {
        switch annotation.metadata {
        case .driveMetadata?: shapes.neighbours["drive", default: 0] += 1
        case .youtubeMetadata?: shapes.neighbours["youtube", default: 0] += 1
        case .videoCallMetadata?: shapes.neighbours["videoCall", default: 0] += 1
        default: break
        }
        if annotation.hasType, annotation.type.rawValue == 24 {
            shapes.neighbours["type24", default: 0] += 1
        }
    }

    private static func countCards(
        _ attachments: [GChatBridgeCore.Attachment], into shapes: inout LinkCardShapes
    ) {
        if !attachments.isEmpty {
            shapes.withAttachmentsField += 1
        }
        for attachment in attachments {
            if let bytes: Data = try? attachment.serializedBytes(),
               !ProtoFieldScan.payloads(ofField: 7, in: bytes).isEmpty {
                shapes.cardsByteScan += 1
            }
            guard attachment.hasCardAddOnData else { continue }
            shapes.cardsDecoded += 1
            let card = attachment.cardAddOnData
            if card.hasHeader {
                shapes.cardsWithHeader += 1
                countText(card.header.title, into: &shapes)
                if !card.header.imageURL.isEmpty {
                    shapes.cardImageHosts[hostClass(card.header.imageURL), default: 0] += 1
                }
            }
            shapes.sections += card.sections.count
            for widget in card.sections.flatMap(\.widgets) {
                countWidget(widget, into: &shapes)
            }
        }
    }

    private static func countWidget(_ widget: JAddOnsWidget, into shapes: inout LinkCardShapes) {
        if let data = widget.data {
            shapes.widgetKinds[widgetKind(data), default: 0] += 1
            countWidgetContent(data, into: &shapes)
        }
        if !widget.buttons.isEmpty {
            shapes.widgetKinds["buttons", default: 0] += 1
            for button in widget.buttons {
                countButton(button, into: &shapes)
            }
        }
        if widget.data == nil, widget.buttons.isEmpty {
            shapes.widgetKinds["empty", default: 0] += 1
        }
        for field in ProtoFieldScan.fields(in: widget.unknownFields.data).fields {
            shapes.unknownWidgetFields[String(field.number), default: 0] += 1
        }
    }

    private static func countWidgetContent(
        _ data: JAddOnsWidget.OneOf_Data, into shapes: inout LinkCardShapes
    ) {
        switch data {
        case let .textParagraph(paragraph):
            countText(paragraph.text, into: &shapes)
        case let .keyValue(value):
            countText(value.content, into: &shapes)
            if case let .button(button)? = value.control {
                countButton(button, into: &shapes)
            }
            if value.hasOnClick {
                shapes.clickKinds[clickKind(value.onClick), default: 0] += 1
            }
        case let .image(image):
            shapes.cardImageHosts[hostClass(image.fifeImageURL), default: 0] += 1
        default:
            break
        }
    }

    /// The generated oneof case's own name - `textParagraph`, `grid`, … - a
    /// closed vocabulary. Only the name before `(` is kept, never the payload.
    private static func widgetKind(_ data: JAddOnsWidget.OneOf_Data) -> String {
        String(String(describing: data).prefix { $0 != "(" })
    }

    private static func countButton(_ button: JAddOnsWidget.Button, into shapes: inout LinkCardShapes) {
        switch button.type {
        case let .textButton(text)?:
            shapes.clickKinds[text.hasOnClick ? clickKind(text.onClick) : "none", default: 0] += 1
        case let .imageButton(image)?:
            let kind = image.hasOnClick ? clickKind(image.onClick) : "none"
            shapes.clickKinds["image:" + kind, default: 0] += 1
        case nil:
            shapes.clickKinds["noButton", default: 0] += 1
        }
    }

    /// `host_app_action` (field 9) is commented out of the vendored proto, so
    /// it is found by bytes rather than read as "none".
    static func clickKind(_ onClick: JAddOnsOnClick) -> String {
        switch onClick.dataCase {
        case .link?: "link"
        case .action?: "action"
        case .openLink?: "openLink"
        case .openLinkAction?: "openLinkAction"
        case .pushCard?: "pushCard"
        case nil:
            ProtoFieldScan.payloads(ofField: 9, in: onClick.unknownFields.data).isEmpty
                ? "none" : "hostAppAction"
        }
    }

    private static func countText(_ text: JAddOnsFormattedText, into shapes: inout LinkCardShapes) {
        if !text.formattedTextElements.isEmpty {
            shapes.textElements += 1
        } else if text.hasOriginalText {
            shapes.textOriginalOnly += 1
            if text.originalText.contains("<") {
                shapes.textOriginalWithMarkup += 1
            }
        }
    }
}

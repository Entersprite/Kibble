import ChatKit
import Foundation
import GChatBridgeCore

/// Provider cards rendered as semantic content. Form-free callbacks are mapped
/// separately; cards requiring unsupported inputs retain a web handoff.
enum CardMapping {
    static func cards(_ attachments: [GChatBridgeCore.Attachment], group: GroupId? = nil) -> [AppCard] {
        attachments.compactMap { attachment in
            guard attachment.hasCardAddOnData else { return nil }
            var mapped = card(attachment.cardAddOnData)
            let interaction = CardInteractionMapping.map(attachment, group: group)
            mapped.actions = interaction.actions.isEmpty ? nil : interaction.actions
            mapped.interactionFallback = interaction.fallback
            return mapped
        }
    }

    static func card(_ item: JAddOnsCardItem) -> AppCard {
        var sections = item.sections.compactMap(section)
        var footer = item.fixedFooter.buttons.compactMap(linkButton)
        for value in [item.fixedFooter.primaryButton, item.fixedFooter.secondaryButton] {
            var button = JAddOnsWidget.Button()
            button.textButton = value
            if let mapped = linkButton(button) {
                footer.append(mapped)
            }
        }
        footer += item.cardActions.compactMap { action in
            link(action.onClick).map { LinkButton(label: action.actionLabel, url: $0) }
        }
        if !footer.isEmpty {
            sections.append(AppCard.Section(widgets: [.buttons(footer)]))
        }
        return AppCard(header: item.hasHeader ? header(item.header) : nil, sections: sections)
    }

    /// One wire widget can be two here: its data, then its row of buttons.
    static func widgets(_ widget: JAddOnsWidget) -> [AppCard.Widget] {
        var mapped = widget.data.flatMap(dataWidget).map { [$0] } ?? []
        let buttons = widget.buttons.compactMap(linkButton)
        if !buttons.isEmpty {
            mapped.append(.buttons(buttons))
        }
        return mapped
    }

    /// `link`, else `open_link.url` (purple's order); every other click kind
    /// is a callback into the app, and `nil`.
    static func link(_ onClick: JAddOnsOnClick) -> URL? {
        switch onClick.dataCase {
        case let .link(raw)?: target(raw)
        case let .openLink(open)?: target(open.url)
        default: nil
        }
    }

    /// `http`, `https` or `mailto`: the schemes `LinkPolicy` opens.
    static func target(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return url
    }

    private static func dataWidget(_ data: JAddOnsWidget.OneOf_Data) -> AppCard.Widget? {
        switch data {
        case let .textParagraph(paragraph):
            RichTextMapping.text(paragraph.text).map(AppCard.Widget.text)
        case let .keyValue(value):
            decorated(value).map(AppCard.Widget.decorated)
        case let .textKeyValue(pair):
            RichTextMapping.text(pair.text).map { content in
                .decorated(AppCard.Decorated(
                    top: RichTextMapping.text(pair.key), content: content,
                    link: pair.hasOnClick ? link(pair.onClick) : nil
                ))
            }
        case let .imageKeyValue(pair):
            RichTextMapping.text(pair.text).map { content in
                .decorated(AppCard.Decorated(
                    content: content, iconURL: image(pair.iconURL),
                    link: pair.hasOnClick ? link(pair.onClick) : nil
                ))
            }
        case let .image(picture):
            image(picture.fifeImageURL).map { url in
                .image(AppCard.Picture(
                    url: url,
                    // Finite only: the store's JSON encoder throws on infinity or NaN.
                    aspectRatio: picture.hasAspectRatio && picture.aspectRatio.isFinite && picture
                        .aspectRatio > 0
                        ? picture.aspectRatio : nil,
                    altText: picture.altText.isEmpty ? nil : picture.altText,
                    link: picture.hasOnClick ? link(picture.onClick) : nil
                ))
            }
        case .divider:
            .divider
        default:
            nil
        }
    }

    private static func header(_ header: JAddOnsCardItem.CardItemHeader) -> AppCard.Header? {
        guard header.hasTitle, let title = RichTextMapping.text(header.title) else { return nil }
        return AppCard.Header(
            title: title,
            subtitle: header.hasSubtitle ? RichTextMapping.text(header.subtitle) : nil,
            imageURL: image(header.imageURL),
            circularImage: header.hasImageStyle && header.imageStyle == .circle
        )
    }

    private static func section(_ section: JAddOnsCardItem.CardItemSection) -> AppCard.Section? {
        let header = section.hasHeader ? RichTextMapping.text(section.header) : nil
        let widgets = section.widgets.flatMap(widgets)
        guard header != nil || !widgets.isEmpty else { return nil }
        return AppCard.Section(header: header, widgets: widgets)
    }

    private static func decorated(_ value: JAddOnsWidget.KeyValue) -> AppCard.Decorated? {
        guard value.hasContent, let content = RichTextMapping.text(value.content) else { return nil }
        var button: LinkButton?
        if case let .button(wire)? = value.control {
            button = linkButton(wire)
        }
        return AppCard.Decorated(
            top: value.hasTopLabel ? RichTextMapping.text(value.topLabel) : nil,
            content: content,
            bottom: value.hasBottomLabel ? RichTextMapping.text(value.bottomLabel) : nil,
            iconURL: image(value.iconURL) ?? (value.hasStartIcon ? image(value.startIcon.iconURL) : nil),
            link: value.hasOnClick ? link(value.onClick) : nil,
            button: button
        )
    }

    private static func linkButton(_ button: JAddOnsWidget.Button) -> LinkButton? {
        guard case let .textButton(text)? = button.type, !text.disabled, text.hasOnClick,
              let url = link(text.onClick),
              let label = RichTextMapping.text(text.text)?.plainText
        else { return nil }
        return LinkButton(label: label, url: url)
    }

    /// `https` only, the rule every remote image follows.
    private static func image(_ raw: String) -> URL? {
        URL(string: raw).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
    }
}

import ChatKit
import Foundation
import GChatBridgeCore

/// Opaque identifiers retain the provider-issued action exactly. They contain
/// no session credentials, and are validated against fresh message data before use.
enum CardInteractionMapping {
    struct Token: Codable {
        let bot: Data
        let action: Data
    }

    struct Mapping {
        var actions: [AppCardAction] = []
        var fallback: LinkButton?
    }

    static func map(_ attachment: GChatBridgeCore.Attachment, group: GroupId?) -> Mapping {
        let card = attachment.cardAddOnData
        let bot = attachment.hasAppID ? attachment.appID : attachment.appUser.userID
        var collector = Collector()
        card.sections.flatMap(\.widgets).forEach { collector.widget($0) }
        card.cardActions.forEach { collector.click($0.onClick, label: $0.actionLabel) }
        card.fixedFooter.buttons.forEach { collector.button($0) }
        for value in [card.fixedFooter.primaryButton, card.fixedFooter.secondaryButton]
            where !value.disabled {
            collector.click(value.onClick, label: RichTextMapping.text(value.text)?.plainText ?? "App action")
        }
        let callbacks = collector.callbacks
        let needsWeb = collector.needsWeb
        let fallback = (needsWeb || !callbacks.isEmpty) ? webLink(group) : nil
        guard !needsWeb, !bot.id.isEmpty, let botData = try? bot.serializedData() else {
            return Mapping(fallback: fallback)
        }
        let actions = callbacks.prefix(64).compactMap { label, action -> AppCardAction? in
            guard !action.actionMethodName.isEmpty || !action.encryptedAction.isEmpty,
                  let bytes = try? action.serializedData(), bytes.count <= 32768,
                  let token = encodedToken(Token(bot: botData, action: bytes))
            else { return nil }
            return AppCardAction(id: token.base64EncodedString(), label: String(label.prefix(200)))
        }
        return Mapping(actions: actions, fallback: fallback)
    }

    private static func encodedToken(_ token: Token) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(token)
    }

    private struct Collector {
        var callbacks: [(String, JAddOnsFormAction)] = []
        var needsWeb = false

        mutating func click(_ value: JAddOnsOnClick, label: String) {
            guard case let .action(action)? = value.dataCase else {
                switch value.dataCase {
                case .openLinkAction?, .pushCard?: needsWeb = true
                default: needsWeb = needsWeb || !value.unknownFields.data.isEmpty
                }
                return
            }
            if !action.unknownFields.data.isEmpty || action.interaction != 0
                || !action.requiredWidgetIds.isEmpty || action.allWidgetsAreRequired {
                needsWeb = true
            }
            callbacks.append((label, action))
        }

        mutating func button(_ value: JAddOnsWidget.Button) {
            switch value.type {
            case let .textButton(text)?:
                guard !text.disabled else { return }
                click(text.onClick, label: RichTextMapping.text(text.text)?.plainText ?? "App action")
            case let .imageButton(image)?:
                click(image.onClick, label: image.name.isEmpty ? "App action" : image.name)
            default: break
            }
        }

        mutating func widget(_ widget: JAddOnsWidget) {
            widget.buttons.forEach { button($0) }
            switch widget.data {
            case .textField?, .selectionControl?, .menu?, .dateTimePicker?: needsWeb = true
            case let .keyValue(row)?:
                click(row.onClick, label: RichTextMapping.text(row.content)?.plainText ?? "App action")
                if case let .button(value)? = row.control {
                    button(value)
                }
                if case .switchWidget? = row.control {
                    needsWeb = true
                }
            case let .textKeyValue(row)?:
                click(row.onClick, label: RichTextMapping.text(row.text)?.plainText ?? "App action")
            case let .imageKeyValue(row)?:
                click(row.onClick, label: RichTextMapping.text(row.text)?.plainText ?? "App action")
            case let .image(image)?:
                click(image.onClick, label: image.altText.isEmpty ? "App action" : image.altText)
            default: break
            }
        }
    }

    private static func webLink(_ group: GroupId?) -> LinkButton? {
        guard let group else { return nil }
        let path: String
        let identifier: String
        switch group.id {
        case let .spaceID(value)?: path = "room"; identifier = value.spaceID
        case let .dmID(value)?: path = "dm"; identifier = value.dmID
        default: return nil
        }
        guard !identifier.isEmpty, identifier.utf8.allSatisfy({
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57)
                .contains($0) || $0 == 45 || $0 == 95
        }), let url = URL(string: "https://chat.google.com/\(path)/\(identifier)") else { return nil }
        return LinkButton(label: "Open in Google Chat", url: url)
    }
}

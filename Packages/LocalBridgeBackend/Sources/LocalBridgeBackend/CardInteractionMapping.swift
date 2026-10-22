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

    /// The card's form-free callbacks as native actions. A card that needs a
    /// form, a dialog or another interaction this client cannot complete
    /// gets none, so nothing incomplete is ever submitted; it is never sent
    /// to the web client instead.
    static func actions(_ attachment: GChatBridgeCore.Attachment) -> [AppCardAction] {
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
        guard !collector.unsupported, !bot.id.isEmpty, let botData = try? bot.serializedData() else {
            return []
        }
        return collector.callbacks.prefix(64).compactMap { label, action -> AppCardAction? in
            guard !action.actionMethodName.isEmpty || !action.encryptedAction.isEmpty,
                  let bytes = try? action.serializedData(), bytes.count <= 32768,
                  let token = encodedToken(Token(bot: botData, action: bytes))
            else { return nil }
            return AppCardAction(id: token.base64EncodedString(), label: String(label.prefix(200)))
        }
    }

    private static func encodedToken(_ token: Token) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(token)
    }

    private struct Collector {
        var callbacks: [(String, JAddOnsFormAction)] = []
        var unsupported = false

        mutating func click(_ value: JAddOnsOnClick, label: String) {
            guard case let .action(action)? = value.dataCase else {
                switch value.dataCase {
                case .openLinkAction?, .pushCard?: unsupported = true
                default: unsupported = unsupported || !value.unknownFields.data.isEmpty
                }
                return
            }
            if !action.unknownFields.data.isEmpty || action.interaction != 0
                || !action.requiredWidgetIds.isEmpty || action.allWidgetsAreRequired {
                unsupported = true
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
            case .textField?, .selectionControl?, .menu?, .dateTimePicker?: unsupported = true
            case let .keyValue(row)?:
                click(row.onClick, label: RichTextMapping.text(row.content)?.plainText ?? "App action")
                if case let .button(value)? = row.control {
                    button(value)
                }
                if case .switchWidget? = row.control {
                    unsupported = true
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
}

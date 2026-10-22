import ChatKit
import SwiftUI

/// One level's settings, each defaulting to what it inherits. Used for a
/// section here, and for a conversation by `ConversationNotificationSheet`
/// and `ConversationRuleList`.
public struct NotificationRuleEditor: View {
    private let title: String
    private let rule: NotificationRule
    private let inherited: ResolvedRule
    private let update: (NotificationRule) -> Void

    public init(
        title: String, rule: NotificationRule, inherited: ResolvedRule,
        update: @escaping (NotificationRule) -> Void
    ) {
        self.title = title
        self.rule = rule
        self.inherited = inherited
        self.update = update
    }

    public var body: some View {
        form.navigationTitle(title)
    }

    var form: some View {
        Form {
            NotificationRuleFields(rule: rule, inherited: inherited, update: update)
            Section {
                SettingsResetButton(
                    message: "Reset these notification settings? They will inherit their defaults. "
                        + "This cannot be undone."
                ) { update(NotificationRule()) }
                    .disabled(rule.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

struct NotificationRuleFields: View {
    var title: String?
    @State private var soundNotice: String?
    let rule: NotificationRule
    let inherited: ResolvedRule
    var allowsInheritance = true
    let update: (NotificationRule) -> Void

    var body: some View {
        Section {
            Picker("Notify about", selection: Binding(
                get: { allowsInheritance ? NotifyControl.selected(rule, inherited: inherited)
                    : NotifyControl.shown(NotificationRule.resolve([rule], below: inherited))
                },
                set: { update(NotifyControl.apply($0, to: rule, inherited: inherited)) }
            )) {
                if allowsInheritance {
                    Text("Default (\(Display.title(of: NotifyControl.shown(inherited))))")
                        .tag(NotifyChoice?.none)
                }
                ForEach(NotifyChoice.choices, id: \.self) {
                    Text(Display.title(of: $0)).tag(NotifyChoice?.some($0))
                }
            }
            if NotifyControl.showsDelivery(rule: rule, inherited: inherited) {
                Picker("Deliver as", selection: Binding(
                    get: { allowsInheritance ? rule.delivery : rule.delivery ?? inherited.delivery },
                    set: { value in
                        var changed = rule
                        changed.delivery = value
                        update(changed)
                    }
                )) {
                    if allowsInheritance, NotifyControl.offersDefaultDelivery(
                        rule: rule,
                        inherited: inherited
                    ) {
                        Text("Default (\(Display.title(of: defaultDelivery)))").tag(Delivery?.none)
                    }
                    ForEach(Delivery.audibleChoices, id: \.self) {
                        Text(Display.title(of: $0)).tag(Delivery?.some($0))
                    }
                }
            }
            choice("Show message previews", \.showsPreview, inherited.showsPreview)
            choice("Show unread indicator", \.showsUnread, inherited.showsUnread)
            choice("Count in Dock badge", \.countsInBadge, inherited.countsInBadge)
            choice("Share typing activity", \.sharesTyping, inherited.sharesTyping)
            choice("Send read receipts", \.readReceipts, inherited.readReceipts)
            NotificationSoundPicker(
                value: rule.sound, inherited: inherited.sound, allowsInheritance: allowsInheritance,
                notice: $soundNotice
            ) { value in
                var changed = rule
                changed.sound = value
                update(changed)
            }
        } header: {
            if let title {
                Text(title)
            }
        } footer: {
            if let soundNotice {
                Text(soundNotice)
            }
        }
    }

    /// "Deliver as"'s Default: what this level delivers as with no delivery
    /// of its own, not `inherited.delivery` (`NotifyControl.defaultDelivery`).
    private var defaultDelivery: Delivery {
        NotifyControl.defaultDelivery(rule: rule, inherited: inherited)
    }

    @ViewBuilder private func choice(
        _ label: String,
        _ field: WritableKeyPath<NotificationRule, Bool?>,
        _ fallback: Bool
    ) -> some View {
        if !allowsInheritance {
            Toggle(label, isOn: Binding(
                get: { rule[keyPath: field] ?? fallback },
                set: { value in
                    var changed = rule
                    changed[keyPath: field] = value
                    update(changed)
                }
            ))
        } else {
            Picker(label, selection: Binding(
                get: { allowsInheritance ? rule[keyPath: field] : rule[keyPath: field] ?? fallback },
                set: { value in
                    var changed = rule
                    changed[keyPath: field] = value
                    update(changed)
                }
            )) {
                if allowsInheritance {
                    Text("Default (\(fallback ? "On" : "Off"))").tag(Bool?.none)
                }
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        }
    }
}

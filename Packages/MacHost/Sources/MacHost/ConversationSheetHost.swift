import AppCore
import ChatKit
import DesignSystem
import SwiftUI

/// The main window's "Notifications for <name>" sheet, bound to the live
/// environment. The shell's `.sheet(item:)` draws this and nothing else.
///
/// **A view of its own, so the state is read in a view's `body`.**
/// Observation tracks what a view's `body` reads and redraws the view when it
/// changes. The sheet used to be built inside the shell's `.sheet(item:)`
/// content closure, and whether that closure's reads are tracked was never
/// proven (the slice 2 final review's m3, `[Verify]`). It matters because
/// `NotificationRuleEditor` builds every write from the rule it was last
/// handed. A sheet that did not redraw after one edit would build the next
/// from the stale rule and silently revert the first.
///
/// **It dismisses itself when rules stop being editable** - a sign-out from
/// Settings › Account, a separate window the sheet does not block (m4). Left
/// up, its pickers would write through `settings.update`, which drops every
/// edit made with no account, so the sheet would be a control the seam cannot
/// honour.
///
/// Not unit-tested: both properties need a sheet presented in a real window.
/// They are in the owner's live check `[Verify]`: two edits in a row, closed
/// and reopened, both kept; and Sign Out with the sheet up closes it.
public struct ConversationSheetHost: View {
    private let environment: AppEnvironment
    private let id: Conversation.ID
    @Environment(\.dismiss) private var dismiss

    public init(environment: AppEnvironment, id: Conversation.ID) {
        self.environment = environment
        self.id = id
    }

    public var body: some View {
        ConversationNotificationSheet(
            state: environment.conversationRuleState(for: id),
            update: { environment.settings.update($0, for: .conversation(id)) }
        )
        .onChange(of: environment.canEditNotificationRules) { _, canEdit in
            if !canEdit {
                dismiss()
            }
        }
    }
}

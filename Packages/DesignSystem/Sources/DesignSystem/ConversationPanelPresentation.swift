import ChatKit
import SwiftUI

/// Creation and management are window-modal sheets, as on every Mac: they
/// slide from the toolbar, carry the system's material, and block the window
/// behind them without dimming it by hand.
///
/// The browser model decides what is shown; the sheet only follows it.
/// Dismissing goes back through `closePanel`, which the model refuses while
/// a write is in flight, so the sheet cannot be closed under one either.
struct ConversationPanelPresentation: ViewModifier {
    let state: ChatSceneState
    let actions: ChatSceneActions
    /// What to do once the sheet has gone. A window shows one sheet at a
    /// time, so another sheet (the notification settings) opens only after
    /// this one has finished dismissing.
    @State private var afterDismiss: (() -> Void)?

    private var isPresented: Bool {
        actions.browser != nil && (
            state.browser.creationKind != nil || state.browser.panelTarget != nil
                || state.browser.panelError != nil
        )
    }

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(get: { isPresented }, set: { shown in
                if !shown {
                    actions.browser?.closePanel()
                }
            }),
            onDismiss: {
                let next = afterDismiss
                afterDismiss = nil
                next?()
            },
            content: {
                sheet
            }
        )
    }

    @ViewBuilder private var sheet: some View {
        if let browser = actions.browser {
            ConversationPanelSheet(
                state: state,
                browser: browser,
                media: actions,
                openNotifications: actions.showNotificationSettings.map { show in
                    { id in
                        afterDismiss = { show(id) }
                        browser.closePanel()
                    }
                }
            )
        }
    }
}

/// The sheet's one content view, switching with the model. Sizes differ by
/// content, and the sheet animates between them.
struct ConversationPanelSheet: View {
    let state: ChatSceneState
    let browser: ConversationBrowserActions
    var media: ChatSceneActions?
    let openNotifications: ((Conversation.ID) -> Void)?

    var body: some View {
        Group {
            if let kind = state.browser.creationKind {
                ConversationCreationSheet(kind: kind, state: state, actions: browser)
                    .id(kind)
            } else if let details = state.browser.details {
                Group {
                    if details.membership != .joined, details.conversation.kind == .space {
                        ConversationPreviewSheet(
                            details: details,
                            state: state,
                            actions: browser,
                            media: media
                        )
                    } else {
                        ConversationManagementSheet(
                            details: details,
                            state: state,
                            actions: browser,
                            openNotifications: openNotifications
                        )
                    }
                }
                .id(details.conversation.id)
            } else {
                ConversationLoadingSheet(state: state, actions: browser)
            }
        }
        .interactiveDismissDisabled(state.browser.isSubmitting)
    }
}

/// Details on their way, or why they did not come. With no details asked
/// for, the error is a conversation that could not be opened (a DM opened
/// straight from the People list), and the way on is to review the list.
struct ConversationLoadingSheet: View {
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    var body: some View {
        Group {
            if let error = state.browser.panelError {
                ContentUnavailableView {
                    Label(
                        state.browser.panelTarget == nil
                            ? "Couldn’t Open the Conversation" : "Couldn’t Load Details",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(error)
                } actions: {
                    if let target = state.browser.panelTarget {
                        Button("Try Again") { actions.details(target, false) }
                    } else if state.browser.needsReconciliation {
                        Button("Review Conversations…", action: actions.reviewCreation)
                    }
                }
            } else {
                ProgressView("Loading Details…")
            }
        }
        .frame(width: 380, height: 200)
        // The sheet's own placements: Escape cancels and Return is Done,
        // with no shortcut written here.
        .toolbar {
            if state.browser.panelError == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: actions.closePanel)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: actions.closePanel)
                }
            }
        }
        .onExitCommand(perform: actions.closePanel)
    }
}

/// A sheet's title and what it is for, above its form.
struct SheetHeader<Accessory: View>: View {
    let title: String
    var message: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            accessory
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String, message: String? = nil) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

/// An error a sheet could not hide behind its buttons.
struct SheetErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }
}

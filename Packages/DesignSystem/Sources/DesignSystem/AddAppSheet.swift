import ChatKit
import SwiftUI

/// Add App…, a small sheet over the Info sheet: a search of the apps that
/// can join the conversation. Choosing one (Add, Return or a double-click)
/// adds it at once and closes the sheet. Apps already here are never offered,
/// whatever the search returns.
struct AddAppSheet: View {
    let conversationName: String
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Member.ID?

    private var browser: ConversationBrowserScene {
        state.browser
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
    }

    private var results: [ConversationApp] {
        let installed = Set(browser.integrations?.apps.map(\.id) ?? [])
        return browser.appResults.filter { !installed.contains($0.id) }
    }

    /// The selected app, while the results still offer it.
    private var chosen: Member.ID? {
        results.contains { $0.id == selection } ? selection : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(title: "Add App", message: "Choose an app to add to \(conversationName).")
            TextField("Search", text: $query, prompt: Text("Search apps"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .padding(.horizontal, 20)
                .onChange(of: query) { actions.searchApps(query) }
            // The Info sheet's header, which shows a refused search, is under this sheet.
            if let error = browser.panelError {
                SheetErrorRow(message: error).padding(.horizontal, 20)
            }
            List(selection: $selection) {
                ForEach(results) { app in
                    AppRow(app: app).tag(app.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Member.ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                ids.first.map(choose)
            }
            .overlay { emptyState }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 360, idealHeight: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { chosen.map(choose) }
                    .disabled(chosen == nil || busy)
            }
        }
        .onAppear { actions.searchApps(query) }
    }

    @ViewBuilder private var emptyState: some View {
        if results.isEmpty {
            if browser.isSearchingApps {
                ProgressView().controlSize(.small)
            } else if query.isEmpty {
                Text("No apps to add").foregroundStyle(.secondary)
            } else {
                Text("No apps match “\(query)”.").foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ app: Member.ID) {
        guard !busy, results.contains(where: { $0.id == app }) else { return }
        actions.mutate(.addApp(app))
        dismiss()
    }
}

/// An app as Integrations lists one: its picture, name and what it does.
struct AppRow<Trailing: View>: View {
    let app: ConversationApp
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            // The name is beside it: VoiceOver reads that, not the initials.
            Avatar(member: app.id, directory: [app.id: app.member], size: 28).besideName()
            VStack(alignment: .leading, spacing: 1) {
                Text(AppName.of(app)).lineLimit(1)
                if let description = app.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
    }
}

/// An app's name as a list shows it.
enum AppName {
    static func of(_ app: ConversationApp) -> String {
        app.member.displayName ?? app.member.email ?? "Unknown App"
    }
}

extension AppRow where Trailing == EmptyView {
    init(app: ConversationApp) {
        self.init(app: app) { EmptyView() }
    }
}

/// A webhook's picture: its avatar, through the scene's image loader, or
/// the link symbol when it has none or it can't be shown.
struct WebhookIcon: View {
    let url: URL?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url {
                SceneImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    glyph
                }
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        // Always beside the webhook's name, which VoiceOver reads instead.
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: IntegrationSymbols.webhook)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}

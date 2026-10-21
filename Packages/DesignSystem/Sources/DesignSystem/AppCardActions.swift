import ChatKit
import SwiftUI

public typealias AppCardActionHandler = @MainActor @Sendable (AppCardActionRequest) async throws
    -> AppCardActionResult

public extension EnvironmentValues {
    @Entry var invokeCardAction: AppCardActionHandler?
}

struct AppCardControls: View {
    let card: AppCard
    let perform: (@MainActor (AppCardAction) async throws -> AppCardActionResult)?
    @State private var selected: AppCardAction?
    @State private var response: AppCardActionResult?
    @State private var failure: String?
    @State private var submitted = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let perform, let actions = card.actions, !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { buttons(actions) }
                    VStack(alignment: .leading) { buttons(actions) }
                }
                .task(id: selected) {
                    guard let selected else { return }
                    busy = true
                    defer { busy = false }
                    do {
                        let result = try await perform(selected)
                        try Task.checkCancellation()
                        response = result
                    } catch {
                        guard !Task.isCancelled else { return }
                        failure = "The action could not be confirmed. Check the app before trying again."
                    }
                }
            }
            if busy {
                ProgressView().controlSize(.small)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
            if let response {
                if let result = response.card {
                    AppCardView(card: result, load: nil)
                } else {
                    Text("Sent to app.").font(.caption).foregroundStyle(.secondary)
                }
                if let url = response.setupURL {
                    Link("Set up app", destination: url)
                }
            }
            if let link = card.interactionFallback {
                Link(link.label, destination: link.url).font(.callout)
            }
        }
    }

    private func buttons(_ actions: [AppCardAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action.label) {
                submitted = true
                selected = action
            }
            .buttonStyle(.bordered)
            .disabled(submitted)
        }
    }
}

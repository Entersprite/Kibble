import ChatKit
import Foundation

/// The open panel's own reads, by kind: a new read replaces the last of its kind.
enum ConversationInfoRead: Hashable {
    case integrations, apps, webhookURL, email, conversion, allParticipants
}

/// The Conversation Info sheet's reads. Each captures the open panel and the
/// account generation before it awaits, and its answer lands only while both,
/// and the browser, are unchanged; a late answer is dropped.
public extension ConversationBrowser {
    func loadIntegrations() {
        let engine = engine
        let capabilities = engine.capabilities
        guard capabilities.canManageConversationApps || capabilities.canManageConversationWebhooks
        else { return }
        integrationsError = nil
        isLoadingIntegrations = read(
            .integrations,
            fetch: { try await engine.loadConversationIntegrations($0) },
            land: { browser, result in
                browser.isLoadingIntegrations = false
                do {
                    browser.integrations = try result.get()
                } catch {
                    browser.integrationsError = Self.message(error)
                }
            }
        )
    }

    /// Debounced as the people search is.
    func searchApps(_ query: String) {
        let engine = engine
        infoTasks[.apps]?.cancel()
        appResults = []
        guard engine.capabilities.canManageConversationApps else {
            isSearchingApps = false
            return
        }
        if !needsReconciliation {
            panelError = nil
        }
        isSearchingApps = read(.apps, fetch: {
            try await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 200))
            return try await engine.searchConversationApps(query, in: $0)
        }, land: { browser, result in
            browser.isSearchingApps = false
            do {
                browser.appResults = try result.get()
            } catch {
                browser.panelError = Self.message(error)
            }
        })
    }

    /// Opens the app's own conversation, then closes the panel and shows it.
    func openApp(_ app: Member.ID) {
        guard let id = panelTarget, !isSubmitting, !stopped else { return }
        isSubmitting = true
        panelError = nil
        let generation = generation
        writeTask = Task { [weak self, engine] in
            do {
                let opened = try await engine.openAppConversation(app, from: id)
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                guard panelTarget == id else { return }
                closePanel()
                onOpen?(opened)
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                if panelTarget == id {
                    panelError = Self.message(error)
                }
            }
        }
    }

    /// Hands a webhook's delivery URL, a credential, to `done` and keeps no
    /// copy. A late answer, after the panel moved on, is dropped unseen.
    func webhookURL(
        _ webhookID: String,
        _ done: @escaping @MainActor (Result<URL, ChatError>) -> Void
    ) {
        let engine = engine
        _ = read(
            .webhookURL,
            fetch: { try await engine.webhookDeliveryURL(webhookID, in: $0) },
            land: { _, result in
                done(result.mapError { .unknown(Self.message($0)) })
            }
        )
    }

    func loadEmail() {
        let engine = engine
        guard engine.capabilities.canManageConversationEmail else { return }
        emailError = nil
        isLoadingEmail = read(
            .email,
            fetch: { try await engine.loadConversationEmail($0) },
            land: { browser, result in
                browser.isLoadingEmail = false
                do {
                    browser.email = try result.get()
                } catch {
                    browser.emailError = Self.message(error)
                }
            }
        )
    }

    func loadConversion() {
        let engine = engine
        conversionError = nil
        isLoadingConversion = read(
            .conversion,
            fetch: { try await engine.loadConversionConsequences($0) },
            land: { browser, result in
                browser.isLoadingConversion = false
                do {
                    browser.conversion = try result.get()
                } catch {
                    browser.conversionError = Self.message(error)
                }
            }
        )
    }

    /// Pages the people list to its end with the panel's own paging. A failed
    /// page stops here and leaves the rest to load later.
    func loadAllParticipants() {
        guard let id = panelTarget, details?.conversation.id == id, details?.membership == .joined,
              participantCursor != nil, !isLoadingAllParticipants, !stopped else { return }
        isLoadingAllParticipants = true
        let generation = generation
        infoTasks[.allParticipants] = Task { [weak self] in
            await self?.detailsTask?.value
            while let self, !Task.isCancelled, isCurrent(id, generation), let cursor = participantCursor {
                openDetails(id, more: true)
                await detailsTask?.value
                if panelError != nil || participantCursor == cursor {
                    break
                }
            }
            guard let self, !Task.isCancelled, isCurrent(id, generation) else { return }
            isLoadingAllParticipants = false
        }
    }

    internal func reloadInfo(after mutation: ConversationMutation) {
        switch mutation {
        case .addApp, .removeApp, .saveWebhook, .deleteWebhook: loadIntegrations()
        case .generateEmail, .setEmailDelivery, .deleteEmail: loadEmail()
        default: break
        }
    }

    internal func forgetInfo() {
        infoTasks.values.forEach { $0.cancel() }
        infoTasks = [:]
        integrations = nil; isLoadingIntegrations = false; integrationsError = nil
        appResults = []; isSearchingApps = false
        email = nil; isLoadingEmail = false; emailError = nil
        conversion = nil; isLoadingConversion = false; conversionError = nil
        isLoadingAllParticipants = false
    }

    private func isCurrent(_ id: Conversation.ID, _ generation: Int) -> Bool {
        !stopped && self.generation == generation && panelTarget == id
    }

    /// Starts `kind`'s read of the open panel, replacing the last one, and
    /// lands its answer only while it is current. Returns whether it started.
    private func read<Value: Sendable>(
        _ kind: ConversationInfoRead,
        fetch: @escaping @Sendable (Conversation.ID) async throws -> Value,
        land: @escaping @MainActor (ConversationBrowser, Result<Value, any Error>) -> Void
    ) -> Bool {
        infoTasks[kind]?.cancel()
        guard let id = panelTarget, !stopped else { return false }
        let generation = generation
        infoTasks[kind] = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = try await .success(fetch(id))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, isCurrent(id, generation) else { return }
            land(self, result)
        }
        return true
    }
}

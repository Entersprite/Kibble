import ChatAPI
import ChatKit
import Foundation
import Observation
import ServiceClient

/// Process-owned client sessions. Selection changes viewing, never account
/// provider lifetime. Every account operation uses the shared API facade.
@MainActor
@Observable
public final class AccountWorkspace {
    public internal(set) var accounts: [AccountSummary] = []
    public internal(set) var pendingLinks: [AccountLinkSummary] = []
    public private(set) var selectedID: ConnectedAccountID?
    public private(set) var windowRequests = 0
    public internal(set) var isLoading = true
    public internal(set) var error: String?
    public internal(set) var accountErrors: [ConnectedAccountID: String] = [:]
    public private(set) var capture: AccountLinkSummary?
    let client: AccountClient
    let host: any AccountSessionHost
    var sessions: [ConnectedAccountID: AccountClientSession] = [:]
    var cleanupSessions: [ConnectedAccountID: AccountClientSession] = [:]
    var cleanupRecords: [ConnectedAccountID: AccountSummary] = [:]
    var cleanedBindings: [ConnectedAccountID: ServiceAccountRevision] = [:]
    var intents: [ConnectedAccountID: AccountClientIntent] = [:]
    @ObservationIgnored var jobs: [ConnectedAccountID: Task<Void, Never>] = [:]
    @ObservationIgnored var generations: [ConnectedAccountID: UUID] = [:]
    /// Each account's own photo as last shown, so a disabled or signed-out
    /// account keeps its face in the account panel. Memory only.
    @ObservationIgnored var ownPhotos: [ConnectedAccountID: OwnPhoto] = [:]
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private let selectionChanged: (ConnectedAccountID?) -> Void
    var active = false
    var windowOpen = false
    var minimized = false
    var deviceActive = true
    var stopped = false
    var prepared = false
    var captureChanging = false

    public init(
        client: AccountClient, host: any AccountSessionHost, selected: ConnectedAccountID? = nil,
        selectionChanged: @escaping (ConnectedAccountID?) -> Void = { _ in }
    ) {
        self.client = client
        self.host = host
        selectedID = selected
        self.selectionChanged = selectionChanged
    }

    public var selectedEnvironment: AppEnvironment? {
        guard let selectedID else { return nil }
        return environment(for: selectedID)
    }

    public func environment(for id: ConnectedAccountID) -> AppEnvironment? {
        guard !stopped, let account = accounts.first(where: { $0.id == id }), canRun(account),
              let session = sessions[id], AccountClientIntent(session.account) == AccountClientIntent(account)
        else { return nil }
        return session.environment
    }

    public var badgeCount: Int {
        accounts.compactMap { environment(for: $0.id) }.reduce(0) { $0 + $1.badgeCount }
    }

    public func releasePresentationCaches() {
        for session in sessions.values {
            session.environment.releasePresentationCaches()
        }
    }

    public func start() {
        guard watcher == nil, !stopped else { return }
        watcher = Task { [weak self, client] in
            while !Task.isCancelled {
                do {
                    let states = try await client.states()
                    for try await state in states {
                        guard !Task.isCancelled, let self, !self.stopped else { return }
                        if !prepared {
                            try await host.prepareForAccounts(state.accounts)
                            try Task.checkCancellation()
                            prepared = true
                        }
                        receive(state)
                    }
                    try Task.checkCancellation()
                    throw ServiceFailure.invalidResponse
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.error = "Account updates are unavailable. Retrying…"
                    self?.sessions.values.forEach { $0.environment.policyControlAvailable(false) }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    public func select(_ id: ConnectedAccountID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectionChanged(id)
        applyViewing()
    }

    public func showAccount(_ id: ConnectedAccountID) {
        guard !stopped, accounts.contains(where: { $0.id == id }) else { return }
        select(id)
        windowRequests += 1
    }

    public func setViewing(active: Bool, windowOpen: Bool, minimized: Bool) {
        self.active = active
        self.windowOpen = windowOpen
        self.minimized = minimized
        applyViewing()
    }

    public func setDeviceActive(_ active: Bool) {
        deviceActive = active
        for session in sessions.values {
            session.environment.setDeviceActive(active)
        }
    }

    public func setEnabled(_ enabled: Bool, account: ConnectedAccountID) async throws {
        _ = try await client.setEnabled(enabled, account: account)
    }

    public func remove(_ account: ConnectedAccountID, forgettingSettings: Bool = false) async throws {
        if capture?.accountID == account {
            try await cancelCapture()
        }
        try await client.remove(account, forgettingSettings: forgettingSettings)
        ownPhotos[account] = nil
    }

    /// Lists the accounts in this order: the panel's tiles and ⌃⌘1…9 follow it.
    public func reorder(_ order: [ConnectedAccountID]) async throws {
        try await client.reorder(order)
    }

    /// Keeps the account and its settings; it waits for a sign-in as the same
    /// identity. The client's local copy goes with the service's.
    public func signOut(_ account: ConnectedAccountID) async throws {
        if capture?.accountID == account {
            try await cancelCapture()
        }
        _ = try await client.signOut(account)
    }

    public func retry(_ id: ConnectedAccountID) async {
        accountErrors[id] = nil
        if let account = accounts.first(where: { $0.id == id }) {
            if account.authenticationState == "erasing" || account.isEnabled && !account.isReady {
                do {
                    _ = try await client.retryRecovery(id)
                } catch { accountErrors[id] = "This account could not recover. Try again." }
            }
            schedule(account, previous: nil, force: true)
        } else if let record = cleanupRecords[id] {
            scheduleRemoval(record)
        }
    }

    public func beginLink(replacing account: ConnectedAccountID? = nil) async throws {
        guard !stopped, prepared, capture == nil,
              !captureChanging else { throw ServiceFailure.operationConflict }
        captureChanging = true
        defer { captureChanging = false }
        for task in Array(jobs.values) {
            await task.value
        }
        try Task.checkCancellation()
        guard !stopped, cleanupRecords.isEmpty else { throw ServiceFailure.accountCleanupPending }
        capture = try await client.beginLink(
            operationID: ServiceOperationID(ClientOperationID.make()),
            replacing: account
        )
    }

    public func resumeLink(_ id: AccountLinkID) async throws {
        guard !stopped, prepared, capture == nil, !captureChanging, cleanupRecords.isEmpty
        else { throw ServiceFailure.accountCleanupPending }
        captureChanging = true
        defer { captureChanging = false }
        let link = try await client.link(id)
        if link.phase == "pendingCapture" {
            capture = link
        } else {
            _ = try await client.completeLink(id)
        }
    }

    /// The completed link: an `alreadyConnected` one names the existing account.
    @discardableResult
    public func completeCapture() async throws -> AccountLinkSummary? {
        guard let capture else { return nil }
        guard !captureChanging else { throw ServiceFailure.operationConflict }
        captureChanging = true
        defer { captureChanging = false }
        let summary = try await client.completeLink(capture.id)
        self.capture = nil
        return summary
    }

    public func cancelCapture() async throws {
        guard let capture else { return }
        guard !captureChanging else { throw ServiceFailure.operationConflict }
        captureChanging = true
        defer { captureChanging = false }
        _ = try await client.cancelLink(capture.id)
        self.capture = nil
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        watcher?.cancel()
        await watcher?.value
        watcher = nil
        let pending = Array(jobs.values)
        for task in pending {
            task.cancel()
        }
        for task in pending {
            await task.value
        }
        jobs.removeAll()
        for session in sessions
            .values {
            try? await session.environment.detachClient(erasingPrivateData: false)
        }
        sessions.removeAll()
    }

    func receive(_ state: AccountStateSnapshot) {
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let order = accounts.map(\.id)
        accounts = state.accounts
        host.updateAccountState(state.accounts)
        pendingLinks = state.pendingLinks
        isLoading = false
        error = nil
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = Self.neighbor(of: selectedID, in: order, remaining: accounts)
            selectionChanged(selectedID)
        }
        for account in accounts {
            if account.isEnabled, !account.isRemoving, account.authenticationState == nil,
               !account.isReady, account.runtimeID == nil, previous[account.id]?.isReady == true {
                accountErrors[account.id] = "This account stopped syncing. Try again."
            }
            sessions[account.id]?.environment.policyControlAvailable(true)
            sessions[account.id]?.environment.policyRevisionChanged(account.policyRevision)
            schedule(account, previous: previous[account.id])
        }
        let remaining = Set(accounts.map(\.id))
        for account in previous.values where !remaining.contains(account.id) {
            scheduleRemoval(account)
        }
        applyViewing()
    }

    func canRun(_ account: AccountSummary) -> Bool {
        account.isEnabled && account.isReady && !account.isRemoving &&
            account.authenticationState == nil && account.revision != nil
    }

    func applyViewing() {
        for (id, session) in sessions {
            let selected = id == selectedID
            session.environment.setWindowOpen(windowOpen && selected)
            session.environment.setWindowMinimized(minimized || !selected)
            session.environment.setActive(active && selected)
        }
    }

    /// After the selected account goes away, the one that followed it, else
    /// the one before it, so a removal never jumps back to the top of the list.
    static func neighbor(
        of gone: ConnectedAccountID?, in order: [ConnectedAccountID], remaining: [AccountSummary]
    ) -> ConnectedAccountID? {
        let ids = Set(remaining.map(\.id))
        guard let gone, let index = order.firstIndex(of: gone) else { return remaining.first?.id }
        return order[(index + 1)...].first(where: ids.contains)
            ?? order[..<index].last(where: ids.contains)
            ?? remaining.first?.id
    }
}

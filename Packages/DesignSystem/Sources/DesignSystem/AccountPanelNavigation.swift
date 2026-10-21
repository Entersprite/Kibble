import SwiftUI

/// A row of the open panel's status section, top to bottom.
enum AccountStatusRow: Hashable {
    case automatic
    case doNotDisturb
    case away
    case setStatus
    case clearStatus

    /// The row's words; Do not disturb's say until when (`StatusMenuModel`).
    func title(_ model: StatusMenuModel) -> String {
        switch self {
        case .automatic: "Automatic"
        case .doNotDisturb: model.doNotDisturbTitle
        case .away: "Set as away"
        case .setStatus: "Set a Status…"
        case .clearStatus: "Clear Status"
        }
    }

    func isChecked(_ model: StatusMenuModel) -> Bool {
        switch self {
        case .automatic: model.isAutomatic
        case .doNotDisturb: model.isDoNotDisturb
        case .away: model.isAway
        case .setStatus, .clearStatus: false
        }
    }
}

/// What VoiceOver says when the panel's one highlight moves. The panel is a
/// single focus stop, so VoiceOver's own cursor cannot follow the arrows:
/// the highlighted row or tile is announced instead, with the same words
/// the panel draws, and whether it is the checked or current one.
@MainActor
enum AccountPanelSpeech {
    static let addTitle = "Add Account"
    static let pendingTitle = "Finish Signing In"
    static let manageTitle = "Manage Accounts…"
    /// The focusable panel's own name.
    static let panelLabel = "Status and Accounts"

    static func text(
        for target: AccountPanelTarget, state: AccountPanelState, status: StatusMenuModel?
    ) -> String? {
        switch target {
        case let .status(row):
            guard let status else { return nil }
            return row.isChecked(status) ? "\(row.title(status)), selected" : row.title(status)
        case let .account(id):
            guard let account = state.accounts.first(where: { $0.id == id }) else { return nil }
            return id == state.selectedID ? "\(account.label), current account" : account.label
        case .pending:
            return pendingTitle
        case .add:
            return addTitle
        case .manage:
            return manageTitle
        }
    }
}

/// What the open panel's one highlight can rest on.
enum AccountPanelTarget: Hashable {
    case status(AccountStatusRow)
    case account(String)
    case pending(String)
    case add
    case manage
}

/// Where the arrows and Tab move the highlight. The panel is two columns: the
/// status rows on the left, and on the right the tiles above Manage Accounts….
/// Moving never chooses anything; Return and Space do.
@MainActor
struct AccountPanelNavigation {
    /// Where the highlight was last in each column, to go back to it.
    struct Recent: Equatable {
        var tile: AccountPanelTarget?
        var status: AccountStatusRow?

        mutating func note(_ target: AccountPanelTarget?) {
            switch target {
            case let .status(row): status = row
            case .account, .pending, .add: tile = target
            case .manage, nil: break
            }
        }
    }

    let status: [AccountStatusRow]
    let tiles: [AccountPanelTarget]
    let manages: Bool
    /// The current account's tile, where the arrows start.
    let initial: AccountPanelTarget?

    init(state: AccountPanelState, actions: AccountPanelActions, status: [AccountStatusRow]) {
        var tiles = state.accounts.map { AccountPanelTarget.account($0.id) }
        if actions.resumeSignIn != nil {
            tiles += state.pendingSignIns.map { .pending($0.id) }
        }
        if actions.add != nil {
            tiles.append(.add)
        }
        self.status = status
        self.tiles = tiles
        manages = actions.manage != nil
        let selected = state.selectedID.map { AccountPanelTarget.account($0) }
        initial = selected.flatMap { tiles.contains($0) ? $0 : nil } ?? tiles.first
            ?? (manages ? .manage : status.first.map { .status($0) })
    }

    /// Every target in reading order, which Tab follows.
    var order: [AccountPanelTarget] {
        status.map { .status($0) } + tiles + (manages ? [.manage] : [])
    }

    /// With nothing highlighted yet, the arrows start from the current account.
    func move(
        from current: AccountPanelTarget?, direction: MoveCommandDirection, recent: Recent = .init()
    ) -> AccountPanelTarget? {
        guard let current = current ?? initial, order.contains(current) else { return initial }
        switch current {
        case let .status(row):
            return moveInStatus(row, direction: direction, recent: recent)
        case .manage:
            switch direction {
            case .up: return tile(recent) ?? current
            case .left: return statusRow(recent) ?? current
            default: return current
            }
        case .account, .pending, .add:
            return moveInTiles(current, direction: direction, recent: recent)
        }
    }

    /// Tab and Shift-Tab, around and back to the start.
    func next(after current: AccountPanelTarget?, backward: Bool) -> AccountPanelTarget? {
        let order = order
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return backward ? order.last : order.first
        }
        return order[(index + (backward ? order.count - 1 : 1)) % order.count]
    }

    private func moveInStatus(
        _ row: AccountStatusRow, direction: MoveCommandDirection, recent: Recent
    ) -> AccountPanelTarget? {
        let index = status.firstIndex(of: row) ?? 0
        switch direction {
        case .up: return .status(status[max(index - 1, 0)])
        case .down: return .status(status[min(index + 1, status.count - 1)])
        case .right: return tile(recent) ?? (manages ? .manage : .status(row))
        default: return .status(row)
        }
    }

    private func moveInTiles(
        _ current: AccountPanelTarget, direction: MoveCommandDirection, recent: Recent
    ) -> AccountPanelTarget? {
        let index = tiles.firstIndex(of: current) ?? 0
        switch direction {
        case .left: return index > 0 ? tiles[index - 1] : statusRow(recent) ?? current
        case .right: return index + 1 < tiles.count ? tiles[index + 1] : current
        case .down: return manages ? .manage : current
        default: return current
        }
    }

    private func tile(_ recent: Recent) -> AccountPanelTarget? {
        if let tile = recent.tile, tiles.contains(tile) {
            return tile
        }
        return tiles.contains { $0 == initial } ? initial : tiles.first
    }

    private func statusRow(_ recent: Recent) -> AccountPanelTarget? {
        if let row = recent.status, status.contains(row) {
            return .status(row)
        }
        return status.first.map { .status($0) }
    }
}

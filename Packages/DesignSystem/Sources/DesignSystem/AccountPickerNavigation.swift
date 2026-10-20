import SwiftUI

enum AccountPickerTarget: Hashable {
    case account(String)
    case pending(String)
    case add
    case manage
}

/// Moves focus only; Return and Space retain native button activation.
@MainActor
struct AccountPickerNavigation {
    let tiles: [AccountPickerTarget]
    let initial: AccountPickerTarget?
    let manages: Bool

    init(state: AccountPanelState, actions: AccountPanelActions) {
        var tiles = state.accounts.map { AccountPickerTarget.account($0.id) }
        if actions.resumeSignIn != nil {
            tiles += state.pendingSignIns.map { .pending($0.id) }
        }
        if actions.add != nil {
            tiles.append(.add)
        }
        self.tiles = tiles
        manages = actions.manage != nil
        let selected = state.selectedID.map { AccountPickerTarget.account($0) }
        initial = selected.flatMap { tiles.contains($0) ? $0 : nil } ?? tiles.first
            ?? (manages ? .manage : nil)
    }

    func move(from current: AccountPickerTarget?, direction: MoveCommandDirection) -> AccountPickerTarget? {
        switch direction {
        case .down: return manages ? .manage : current ?? initial
        case .up: return current == .manage ? initial : current ?? initial
        case .left, .right:
            guard let current, let index = tiles.firstIndex(of: current) else { return initial }
            let next = index + (direction == .left ? -1 : 1)
            return tiles.indices.contains(next) ? tiles[next] : current
        @unknown default: return current
        }
    }
}

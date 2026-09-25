import Foundation

/// Polls instead of counting yields, so a test waits for the thing it needs
/// rather than a budget of turns. `@MainActor`, per `CLAUDE.md`: a
/// nonisolated helper never lets the model's main-actor observations run.
@MainActor
func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

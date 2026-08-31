import ChatKit
import Foundation

/// Plays a script at human speed.
///
/// **The only type in this package that waits.** Everything else - the backend,
/// the world, `play(_:)` - runs instantly and reads no clock, which is what
/// keeps tests above the seam hermetic. The waiting is confined here so that
/// the demo and the suite can share one script and one backend, and so that
/// "does this package sleep anywhere it should not?" is a question with a
/// one-file answer.
///
/// Typical use is the Mac app's Debug backend:
///
/// ```swift
/// let backend = FakeBackend(world: .acme)
/// let driver = FixtureDemoDriver(backend: backend)
/// await driver.start()
/// ```
public actor FixtureDemoDriver {
    private let backend: FakeBackend
    private let script: FixtureScript
    private let repeats: Bool
    private var task: Task<Void, Never>?

    public init(
        backend: FakeBackend,
        script: FixtureScript = .acmeDemo,
        repeats: Bool = true
    ) {
        self.backend = backend
        self.script = script
        self.repeats = repeats
    }

    /// Begins playing, and returns immediately. Calling it while already
    /// running does nothing, so a view that appears twice cannot double the
    /// traffic.
    public func start() {
        guard task == nil else { return }
        task = Task { [backend, script, repeats] in
            await Self.run(script, into: backend, repeats: repeats)
        }
    }

    /// Stops playing. Safe before `start()`, and safe twice.
    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }

    private static func run(_ script: FixtureScript, into backend: FakeBackend, repeats: Bool) async {
        repeat {
            for step in script.steps {
                if Task.isCancelled {
                    return
                }
                if case let .delay(duration) = step {
                    // Cancellation lands here rather than mid-step, which is
                    // why the sleep is the only awaited thing in the loop.
                    try? await Task.sleep(for: duration)
                    continue
                }
                do {
                    try await backend.apply(step)
                } catch {
                    // A script naming something the world does not have is a
                    // bug in the fixture, not a condition to soldier through:
                    // carrying on would leave a demo quietly missing messages
                    // with nothing to explain it. A test plays every shipped
                    // script start to finish so this should be unreachable.
                    await backend.report(error)
                    return
                }
            }
        } while repeats && !Task.isCancelled
    }
}

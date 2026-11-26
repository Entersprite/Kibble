import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func start() {
        guard startup == nil, !stopped else { return }
        let epoch = currentEpoch
        startup = Task { [weak self, providerStarts, instanceID] in
            var attempt = 1
            var delay = Duration.seconds(1)
            while !Task.isCancelled {
                do { try await providerStarts.acquire(instanceID) } catch { return }
                let minimum = await self?.connectAtStartup(epoch: epoch, attempt: attempt)
                await providerStarts.release(instanceID)
                guard let minimum else { return }
                // A sleeping account leaves admission available to other accounts.
                do { try await Task.sleep(for: max(delay, minimum)) } catch { return }
                attempt += 1
                delay = min(delay * 2, .seconds(32))
            }
        }
    }

    private func connectAtStartup(epoch: UUID, attempt: Int) async -> Duration? {
        guard isCurrent(epoch) else { return nil }
        do {
            if backend == nil {
                let provider = try await factory.makeProvider(for: record)
                guard await install(provider, epoch: epoch) else {
                    await provider.discard()
                    return nil
                }
            }
            guard let backend, isCurrent(epoch) else { return nil }
            if let source = checkpointedBackend,
               let storage = storage as? any ServiceProviderCheckpointStorage {
                try await source.connect(resumingProviderCheckpoint: storage.providerCheckpoint())
            } else {
                try await backend.connect()
            }
            // A noncooperative connect can settle after stop began to drain it.
            if !isCurrent(epoch) {
                await backend.disconnect()
            } else if checkpointedBackend == nil {
                await requestWorldRefresh()
            }
            return nil
        } catch {
            guard isCurrent(epoch) else { return nil }
            if backend != nil, let minimum = Self.startupRetryMinimum(for: error) {
                await reportStartupRetry(attempt: attempt)
                return isCurrent(epoch) ? minimum : nil
            }
            await failed(error, epoch: epoch)
            return nil
        }
    }

    private static func startupRetryMinimum(for error: any Error) -> Duration? {
        switch error as? ChatError {
        case .transport, .server(status: 429, message: _):
            .zero
        case let .rateLimited(retryAfter):
            retryAfter ?? .zero
        case let .server(status, _) where (500 ... 599).contains(status):
            .zero
        default:
            nil
        }
    }

    private func reportStartupRetry(attempt: Int) async {
        do {
            try appendAndPublish(
                .connectionStateChanged(.reconnecting(attempt: attempt, issue: nil, detail: nil)),
                live: false
            )
            await publishProviderStatus()
        } catch {
            await quarantine(.storage)
        }
    }

    private func failed(_ error: any Error, epoch: UUID) async {
        guard isCurrent(epoch) else { return }
        if error as? ChatError == .notAuthenticated || error as? ChatError == .sessionExpired {
            await quarantine(.authentication)
            return
        }
        let failure = serviceFailure(error)
        let safe = failure.details.flatMap { try? ServiceCodec.decode(ChatError.self, from: $0) }
            ?? .unknown("The account could not connect.")
        do {
            try appendAndPublish(.backendError(safe), live: false)
            try appendAndPublish(.connectionStateChanged(.disconnected(reason: nil, issue: nil)), live: false)
            await publishProviderStatus()
        } catch {
            await quarantine(.storage)
        }
    }
}

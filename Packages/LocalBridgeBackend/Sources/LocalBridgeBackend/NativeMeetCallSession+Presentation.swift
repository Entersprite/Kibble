import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func preparePresentation() async {
        guard await media.supportsScreenSharing else { return }
        await media.configureScreenSharing(start: { [weak self] media in
            guard let self else { throw CallMediaError.closed }
            try await startPresentation(media)
        }, stop: { [weak self] in
            guard let self else { return false }
            return await stopPresentation()
        })
    }

    func startPresentation(_ engine: any CallMediaEngine) async throws {
        try await check()
        guard ready, presentation == nil, presentationStart == nil else { throw CallMediaError.busy }
        let task = Task { try await performStartPresentation(engine) }
        presentationStart = task
        defer { presentationStart = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performStartPresentation(_ engine: any CallMediaEngine) async throws {
        var presenter: NativeMeetPresentation?
        do {
            try await check()
            let presenterDevice = try await device.makePresenter()
            try await check()
            let child = NativeMeetPresentation(
                client: client,
                device: presenterDevice,
                media: engine,
                validate: validateAccount
            )
            presenter = child
            presentation = child
            try await child.connect()
            try await check()
            if let source = await child.source {
                rememberPresentationSource(source)
            }
            guard presentation === child else { throw CallMediaError.closed }
            lines.append("Native presentation: secondary device connected")
        } catch {
            let stage = await presenter?.stage.rawValue ?? "secondary authorization"
            lines
                .append("Native presentation: " + stage + " failed; " + MeetDMCallTrial
                    .errorDescription(error))
            if let presenter {
                if let source = await presenter.source {
                    rememberPresentationSource(source)
                }
                let confirmed = await presenter.close()
                if presentation === presenter {
                    presentation = nil
                }
                if !confirmed {
                    cleanupStatus.leaveUnconfirmed = true
                    let failure = await presenter.cleanupFailure ?? "leave unconfirmed"
                    lines.append("Native presentation cleanup: " + failure)
                }
            }
            throw error
        }
    }

    func rememberPresentationSource(_ source: MeetVideoSource) {
        guard !ownPresentationSources.contains(source) else { return }
        ownPresentationSources.append(source)
        if ownPresentationSources.count > 32 {
            ownPresentationSources.removeFirst()
        }
    }

    @discardableResult
    func stopPresentation() async -> Bool {
        let starting = presentationStart
        starting?.cancel()
        _ = await starting?.result
        guard let presenter = presentation else { return !cleanupStatus.leaveUnconfirmed }
        if let source = await presenter.source {
            rememberPresentationSource(source)
        }
        let confirmed = await presenter.close()
        if presentation === presenter {
            presentation = nil
        }
        if !confirmed {
            cleanupStatus.leaveUnconfirmed = true
        }
        lines.append(confirmed ? "Native presentation: local media stopped; secondary device left"
            : "Native presentation: local media stopped; secondary device leave unconfirmed")
        return confirmed
    }
}

import AppKit
import Foundation
import LocalBridgeBackend
import Observation

/// Repairs authentication for a Google web app using a temporary browser.
@MainActor
@Observable
public final class CallSignInRecovery {
    enum Destination {
        case calls
        case calendar

        var name: String {
            self == .calls ? "Calls" : "Calendar"
        }

        var signInName: String {
            self == .calls ? "Call" : "Calendar"
        }

        var configuration: LoginWebViewConfiguration {
            self == .calls ? .calls : .calendar
        }
    }

    let destination: Destination
    public private(set) var isAvailable = false
    public private(set) var isActive = false
    public private(set) var isWorking = false
    public private(set) var status = ""
    @ObservationIgnored private var load: (() async throws -> [MeetWebCookieSeed])?
    @ObservationIgnored private var save: (([CapturedCookie]) async throws -> Int)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private weak var webView: (any LoginWebView)?
    @ObservationIgnored private var completion: ((Bool) -> Void)?
    @ObservationIgnored private var windowHost: CallSignInRecoveryWindow?
    @ObservationIgnored private var visitingDestination = false

    init(destination: Destination = .calls) {
        self.destination = destination
    }

    func install(
        load: @escaping () async throws -> [MeetWebCookieSeed],
        save: @escaping ([CapturedCookie]) async throws -> Int
    ) async {
        await invalidate()
        self.load = load
        self.save = save
        isAvailable = true
    }

    func invalidate() async {
        isAvailable = false
        await finish(restart: false)
        load = nil
        save = nil
    }

    func present() async -> Bool {
        guard isAvailable, !isActive else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                begin { continuation.resume(returning: $0) }
                let host = CallSignInRecoveryWindow(model: self)
                windowHost = host
                host.show()
            }
        } onCancel: {
            Task { @MainActor in await self.finish(restart: false) }
        }
    }

    /// Injection point for the native cookie store; tests use an in-memory view.
    func attach(_ view: any LoginWebView, seed: @escaping ([MeetWebCookieSeed]) async -> Void) {
        guard isActive, let load else { return }
        webView = view
        visitingDestination = false
        isWorking = true
        status = "Opening \(destination.signInName) sign-in…"
        let scope = revision
        work = Task {
            do {
                let cookies = try await load()
                guard revision == scope, !Task.isCancelled else { return }
                await seed(cookies)
                guard revision == scope, !Task.isCancelled else { return }
                isWorking = false
                work = nil
                status = "Use the same Google account as Chat."
                openStartPage(view)
            } catch {
                guard revision == scope, !Task.isCancelled else { return }
                isWorking = false
                work = nil
                status = "\(destination.signInName) sign-in couldn't open. Close this window and try again."
            }
        }
    }

    func pageSettled(_ view: any LoginWebView) {
        guard isActive, !isWorking, !finishing, let save else { return }
        if view.currentURL?.host() == LoginWebViewConfiguration.chat.host, !visitingDestination {
            visitingDestination = true
            status = "Finish \(destination.signInName) sign-in with the same Google account."
            view.navigate(to: destination.configuration.startURL)
            return
        }
        guard visitingDestination, view.currentURL?.host() == destination.configuration.host else { return }
        isWorking = true
        status = "Checking \(destination.signInName) sign-in…"
        let scope = revision
        work = Task {
            let cookies = await view.allCookies().map {
                CapturedCookie(
                    name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                    isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly, expiresAt: $0.expiresDate
                )
            }
            guard revision == scope, !Task.isCancelled else { return }
            do {
                let count = try await save(cookies)
                guard revision == scope, !Task.isCancelled else { return }
                isWorking = false
                work = nil
                if count > 0 {
                    await finish(restart: true)
                } else {
                    status = "\(destination.signInName) sign-in isn't ready. Finish signing in and try again."
                }
            } catch {
                guard revision == scope, !Task.isCancelled else { return }
                isWorking = false
                work = nil
                status = (error as? MeetWebCaptureError) == .accountMismatch
                    ? "This is a different Google account. Sign in with your Chat account."
                    : "\(destination.signInName) sign-in couldn't be verified. Try again."
            }
        }
    }

    func retry() {
        guard isActive, !isWorking, !finishing else { return }
        status = "Opening \(destination.signInName) sign-in…"
        if let webView {
            openStartPage(webView)
        }
    }

    private func openStartPage(_ view: any LoginWebView) {
        visitingDestination = destination == .calendar
        let configuration = visitingDestination ? destination.configuration : LoginWebViewConfiguration.chat
        view.navigate(to: configuration.startURL)
    }

    func navigationFailed() {
        guard isActive, !isWorking else { return }
        status = "\(destination.signInName) sign-in couldn't load. Try again, or close this window."
    }

    func finish(restart: Bool) async {
        if let finishTask {
            await finishTask.value; return
        }
        finishing = true
        revision += 1
        let pending = work
        pending?.cancel()
        let task = Task { await self.settle(pending, restart: restart) }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func settle(_ pending: Task<Void, Never>?, restart: Bool) async {
        await pending?.value
        work = nil
        isWorking = false
        isActive = false
        webView = nil
        windowHost?.close()
        windowHost = nil
        let completion = completion
        self.completion = nil
        finishing = false
        completion?(restart && isAvailable)
    }

    func begin(completion: @escaping (Bool) -> Void) {
        isActive = true
        self.completion = completion
    }
}

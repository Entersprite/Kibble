import ChatKit
import Foundation
import Testing
@testable import AppCore

/// Spec §6.1 - the nine launch paths, one test each.
///
/// These are characterization tests over behaviour that already shipped in
/// `Apps/GChatMac`, where nothing could reach it. They are expected to pass on
/// the first run; a failure here is a real bug that has been live, and it
/// should be reported rather than quietly fixed.
@MainActor
struct LaunchDecisionTests {
    private func phaseName(_ phase: LaunchPhase) -> String {
        switch phase {
        case .loading: "loading"
        case .needsSignIn: "needsSignIn"
        case .running: "running"
        case .failed: "failed"
        case .report: "report"
        }
    }

    @Test func aKeychainProbeReplacesTheLaunchAndTouchesNothing() async throws {
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(probe: .keychain)
        )
        services.probeReport = "Written to keychain-check.txt."
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .report(message) = environment.phase else {
            Issue.record("expected .report, got \(phaseName(environment.phase))")
            return
        }
        #expect(message == "Written to keychain-check.txt.")
        #expect(services.calls == [.runProbe(.keychain)])
    }

    @Test func anAPIProbeDoesTheSame() async throws {
        let services = try FakeLaunchServices(arguments: LaunchArguments(probe: .api))
        services.probeReport = "Written to api-probe.txt."
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .report(message) = environment.phase else {
            Issue.record("expected .report, got \(phaseName(environment.phase))")
            return
        }
        #expect(message == "Written to api-probe.txt.")
        #expect(services.calls == [.runProbe(.api)])
        #expect(!services.calls.contains(.openStore))
    }

    @Test func noStoredSessionAsksForOneAndErasesFirst() async throws {
        let services = try FakeLaunchServices()
        services.storedSessionExists = false
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .needsSignIn(reason) = environment.phase else {
            Issue.record("expected .needsSignIn, got \(phaseName(environment.phase))")
            return
        }
        // nil, not a message: a first run is not an error and must not be
        // reported as one.
        #expect(reason == nil)
        #expect(services.calls == [.hasStoredSession, .eraseStore])
    }

    /// `findings.md` §11: a credential store that refuses is not an absent
    /// credential. Reporting it as one sends someone through a two-factor
    /// login that cannot possibly help.
    @Test func aCredentialStoreThatRefusesFailsRatherThanAskingForASignIn() async throws {
        let services = try FakeLaunchServices()
        services.hasStoredSessionFailure = ChatError.unknown("the Keychain refused (-34018)")
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .failed(message) = environment.phase else {
            Issue.record("expected .failed, got \(phaseName(environment.phase))")
            return
        }
        #expect(message.contains("-34018"))
        #expect(!services.calls.contains(.eraseStore))
    }

    @Test func theHappyPathRunsAndClearsEphemeralStateBeforeChoosingABackend() async throws {
        let services = try FakeLaunchServices()
        // Something only true of the previous process, which a fresh launch
        // must not inherit.
        try services.store.apply([.setConnectionState(.connected)])
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(phaseName(environment.phase))")
            return
        }
        // The claim that matters, checked where it happens: by the time a
        // backend was asked for, the previous process's state was already
        // gone. An earlier version of this test compared call-log indices,
        // which would have passed with the clear moved after makeSession().
        #expect(services.connectionStateWhenSessionMade != nil)
        #expect(services.connectionStateWhenSessionMade != .connected)
    }

    /// The commonest way a different account ends up reopening the same
    /// database: the nine-day `COMPASS` fuse (`findings.md` §17.2) burning out.
    @Test func aSessionGoogleNoLongerAcceptsAsksForANewOneWithWords() async throws {
        let services = try FakeLaunchServices()
        services.backend.connectFailure = ChatError.notAuthenticated
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .needsSignIn(reason) = environment.phase else {
            Issue.record("expected .needsSignIn, got \(phaseName(environment.phase))")
            return
        }
        #expect(reason == "Your Google session stopped working. Sign in again.")
    }

    @Test func anyOtherFailureIsReportedAsOne() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("no session in the Keychain")
        let environment = AppEnvironment(services: services)

        await environment.start()

        guard case let .failed(message) = environment.phase else {
            Issue.record("expected .failed, got \(phaseName(environment.phase))")
            return
        }
        #expect(message.contains("no session in the Keychain"))
    }

    @Test func aFixtureWorldGetsDriven() async throws {
        let driver = RecordingDemoDriver()
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(usesRealBackend: false),
            driver: driver
        )
        let environment = AppEnvironment(services: services)

        await environment.start()

        #expect(driver.startCount == 1)
        // The fixture needs no stored session, so nothing should have asked.
        #expect(!services.calls.contains(.hasStoredSession))
    }

    @Test func startingTwiceDoesNotBuildASecondEverything() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)

        await environment.start()
        await environment.start()

        #expect(services.calls.count(where: { $0 == .openStore }) == 1)
        #expect(services.calls.count(where: { $0 == .makeSession }) == 1)
    }

    @Test func diagnosticsStartOnlyWhenAsked() async throws {
        let quiet = try FakeLaunchServices()
        await AppEnvironment(services: quiet).start()
        #expect(!quiet.calls.contains(.startDiagnostics))

        let loud = try FakeLaunchServices(
            arguments: LaunchArguments(runsDiagnostics: true)
        )
        await AppEnvironment(services: loud).start()
        #expect(loud.calls.contains(.startDiagnostics))
    }
}

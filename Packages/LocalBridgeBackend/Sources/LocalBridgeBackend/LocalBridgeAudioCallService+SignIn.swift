import Foundation

public extension LocalBridgeAudioCallService {
    /// The ordinary host's temporary sign-in window never saves a Chat session.
    /// The provider pins the login and verifies both account and call readiness.
    func callSignInCookies() async throws -> [MeetWebCookieSeed] {
        try await trial.callSignInCookies()
    }

    func saveCallSignIn(_ cookies: [CapturedCookie]) async throws -> Int {
        try await trial.saveCallSignIn(cookies)
    }
}

extension MeetDMCallTrial {
    func callSignInCookies() async throws -> [MeetWebCookieSeed] {
        _ = try await loadStoredSession()
        let seeds = try await MeetWebCredentials.seeds(from: store)
        _ = try await loadStoredSession()
        try Task.checkCancellation()
        return seeds
    }

    func saveCallSignIn(_ cookies: [CapturedCookie]) async throws -> Int {
        _ = try await loadStoredSession()
        return try await MeetWebCredentials.save(
            captured: cookies, to: store, expectedSession: expectedSession,
            validatesCallSignIn: true, liveCredentials: sharedCredentials,
            transport: transport, endpoints: endpoints
        )
    }
}

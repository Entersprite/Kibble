import Foundation

public struct MeetDMCallPerson: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let email: String?
}

public struct PreparedMeetDMCall: Sendable {
    public let id: UUID
    public let url: URL
}

public enum MeetDMCallTrialError: Error, Sendable, Equatable {
    case noSession, signedOut, missingSelf, accountChanged, invalidPerson, callNotPrepared, superseded
    case browserJoinRequired, callChanged, missingPushConfiguration
}

public enum MeetDMCallLoadStep: String, Sendable {
    case storedSession = "Reading the saved Chat session…"
    case chatBootstrap = "Connecting to Chat…"
    case selfAccount = "Checking your Chat account…"
    case conversations = "Loading your DM conversations…"
    case profiles = "Loading people's names…"
    case ready = "Checking the loaded people list…"
}

import Foundation

/// Optional explicit joining, separate from starting/ringing a recipient.
/// The provider discovers and revalidates the current meeting internally.
/// No credentials or provider meeting identifiers cross this session seam.
@MainActor
public protocol ExistingAudioCallService: AudioCallService {
    var canJoinExistingCalls: Bool { get }
    func joinExisting(to recipient: AudioCallRecipient, callID: UUID) async throws
}

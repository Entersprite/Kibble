import Foundation

/// Standard meeting notices for an explicit, platform-owned confirmation.
public enum CallAdmissionNotice: String, Sendable, CaseIterable {
    case recording = "Recording"
    case organizationLiveStream = "Live streaming within the organization"
    case transcription = "Transcription"
    case publicLiveStream = "Public live streaming"
    case notes = "AI meeting notes"
    case watermark = "Watermarking"
    case mediaAccess = "A connected app accessing meeting media"
    case automatedParticipant = "An automated participant"
}

import ChatKit
import Foundation

@MainActor
public struct CallActivitiesScene {
    public var state: CallActivitiesState
    public var meetingChat: CallChatScene?
    public var openGuestChat: (@MainActor (UUID) async throws -> Void)?
    public var setRecordingAndTranscriptionEnabled: ((Bool, String?) async throws -> Void)?
    public var perform: (CallActivity) async throws -> Void

    public init(
        state: CallActivitiesState,
        meetingChat: CallChatScene? = nil,
        setRecordingAndTranscriptionEnabled: ((Bool, String?) async throws -> Void)? = nil,
        perform: @escaping (CallActivity) async throws -> Void
    ) {
        self.state = state
        self.meetingChat = meetingChat
        self.setRecordingAndTranscriptionEnabled = setRecordingAndTranscriptionEnabled
        self.perform = perform
    }
}

import Foundation

/// Provider acknowledgements only; local media is already closed in either case.
public struct MeetNativeCallCleanup: Sendable, Equatable {
    public var invitationUnconfirmed = false
    public var leaveUnconfirmed = false

    public var isConfirmed: Bool {
        !invitationUnconfirmed && !leaveUnconfirmed
    }

    public var message: String? {
        switch (invitationUnconfirmed, leaveUnconfirmed) {
        case (false, false): nil
        case (true, false):
            "Audio stopped on this Mac. The calling service hasn't confirmed that ringing was cancelled."
        case (false, true):
            "Audio stopped on this Mac. The calling service hasn't confirmed that this device left the call."
        case (true, true):
            "Audio stopped on this Mac. The calling service hasn't confirmed "
                + "ringing cancellation or device leave."
        }
    }
}

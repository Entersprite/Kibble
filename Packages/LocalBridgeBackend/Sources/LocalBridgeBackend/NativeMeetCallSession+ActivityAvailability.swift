import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    var canMessageWaitingRoom: Bool {
        hostControls.waitingRoomChatGrant?.enabled == true
            && assignedActivityChannels?.contains(.messages) == true
    }

    private static let initialActivityActions = [
        "refresh",
        "react",
        "chat",
        "captions",
        "recording",
        "transcription",
        "notes",
        "attendance",
        "createPoll",
        "votePoll",
        "closePoll",
        "sharePollResults",
        "askQuestion",
        "voteQuestion",
        "answerQuestion",
        "createRooms",
        "createAndOpenRooms",
        "openRooms",
        "closeRooms",
        "assignRoom"
    ]

    static let activitiesBeforeFirstSnapshot = initialActivityActions.filter {
        !["captions", "sharePollResults", "createRooms", "closeRooms", "assignRoom"].contains($0)
    }

    func updateActivityAvailability() {
        var actions = Set(Self.initialActivityActions + availableHostActions())
        if activities.automaticHandLowering != nil {
            actions.insert("keepHandRaised")
        }
        let dependencies: [Int: Set<String>] = [
            1: ["react", "chat", "recording", "transcription", "notes", "attendance"],
            4: ["votePoll", "closePoll", "sharePollResults"],
            5: ["createPoll", "votePoll", "closePoll", "sharePollResults"],
            6: ["voteQuestion", "answerQuestion"],
            7: ["askQuestion", "voteQuestion", "answerQuestion"],
            8: ["createRooms", "createAndOpenRooms", "openRooms", "closeRooms", "assignRoom"],
            9: ["assignRoom"]
        ]
        for field in unavailableActivityFields {
            actions.subtract(dependencies[field] ?? [])
        }
        if !canSendMeetingChat || assignedActivityChannels?.contains(.messages) == false {
            actions.remove("chat")
        }
        if assignedActivityChannels?.contains(.messages) == true, !unavailableActivityFields.contains(3) {
            actions.insert("setMeetingMessagePin")
        }
        if canMessageWaitingRoom {
            actions.insert("chatWaitingRoom")
        } else {
            clearWaitingRoomMessages()
        }
        if hostControls.reactionsLocked || assignedActivityChannels?.contains(.reactions) == false {
            actions.remove("react")
        }
        if assignedActivityChannels?.contains(.captions) != true {
            actions.remove("captions")
        }
        if pollSeries == nil || !pollsAccepting {
            actions.remove("createPoll")
        }
        if questionSeries == nil || !questionsAccepting {
            actions.remove("askQuestion")
        }
        actions.subtract(unavailableRoomActions)
        actions.subtract(deniedActivities)
        activities.availableActions = actions.sorted()
        updateContinuousChatRoute()
    }

    private var unavailableRoomActions: Set<String> {
        if activities.breakoutClosing == true {
            return ["createRooms", "createAndOpenRooms", "openRooms", "closeRooms", "assignRoom"]
        }
        return activities.rooms.contains(where: \.isOpen)
            ? ["createAndOpenRooms", "openRooms"] : ["createRooms", "closeRooms"]
    }

    func updateActivityCollectionFailures(_ unavailable: Set<Int>, confirmed: Set<Int>) {
        let previous = unavailableActivityFields
        unavailableActivityFields.formUnion(unavailable)
        unavailableActivityFields.subtract(confirmed)
        if unavailable.contains(8) {
            // A retained room URL cannot authorize Join after its state fails validation.
            activities.rooms = []
            activities.breakoutClosing = nil
            activities.breakoutClosed = nil
        }
        guard previous != unavailableActivityFields, !unavailableActivityFields.isEmpty else { return }
        let fields = unavailableActivityFields.sorted().map(String.init).joined(separator: ",")
        lines.append("Native meeting activities: unavailable collection fields " + fields
            + "; values withheld. Core call state remains independent.")
    }
}

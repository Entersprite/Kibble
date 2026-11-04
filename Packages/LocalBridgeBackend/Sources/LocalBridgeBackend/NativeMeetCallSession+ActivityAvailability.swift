import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func updateActivityAvailability() {
        var actions: Set = [
            "refresh",
            "react",
            "chat",
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
            "openRooms",
            "closeRooms",
            "assignRoom"
        ]
        actions.subtract(deniedActivities)
        let dependencies: [Int: Set<String>] = [
            1: ["react", "chat", "recording", "transcription", "notes", "attendance"],
            4: ["votePoll", "closePoll", "sharePollResults"],
            5: ["createPoll", "votePoll", "closePoll", "sharePollResults"],
            6: ["voteQuestion", "answerQuestion"],
            7: ["askQuestion", "voteQuestion", "answerQuestion"],
            8: ["createRooms", "openRooms", "closeRooms", "assignRoom"],
            9: ["assignRoom"]
        ]
        for field in unavailableActivityFields {
            actions.subtract(dependencies[field] ?? [])
        }
        if activityChatLocked {
            actions.remove("chat")
        }
        if activityReactionsLocked {
            actions.remove("react")
        }
        if pollSeries == nil || !pollsAccepting {
            actions.remove("createPoll")
        }
        if questionSeries == nil || !questionsAccepting {
            actions.remove("askQuestion")
        }
        activities.availableActions = actions.sorted()
    }

    func updateActivityCollectionFailures(_ unavailable: Set<Int>, confirmed: Set<Int>) {
        let previous = unavailableActivityFields
        unavailableActivityFields.formUnion(unavailable)
        unavailableActivityFields.subtract(confirmed)
        if unavailable.contains(8) {
            // A retained room URL cannot authorize Join after its state fails validation.
            activities.rooms = []
        }
        guard previous != unavailableActivityFields, !unavailableActivityFields.isEmpty else { return }
        let fields = unavailableActivityFields.sorted().map(String.init).joined(separator: ",")
        lines.append("Native meeting activities: unavailable collection fields " + fields
            + "; values withheld. Core call state remains independent.")
    }
}

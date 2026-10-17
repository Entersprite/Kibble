import ChatKit
import Foundation

public extension LocalBridgeAudioCallService {
    func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        guard !isStopping else { return }
        directoryRecipients = recipients
        directoryRevision += 1
        let revision = directoryRevision
        let scope = sessionScope
        let updated = await trial.updatePeople(recipients)
        guard scope == sessionScope, revision == directoryRevision, !isStopping else { return }
        // Initial bootstrap will apply the latest directory once its account
        // context is established. An empty early result is not authoritative.
        guard await trial.hasDirectoryContext else { return }
        guard scope == sessionScope, revision == directoryRevision, !isStopping else { return }
        people = updated
        continuation.yield(.recipientsChanged(updated.values.map(Self.recipient)))
        await incoming?.updatePeople(trial.incomingPeople())
    }
}

extension MeetDMCallTrial {
    var hasDirectoryContext: Bool {
        context != nil
    }

    func updatePeople(_ recipients: [AudioCallRecipient]) -> [UUID: MeetDMCallPerson] {
        guard let selfID, context != nil else { return [:] }
        var updated: [UUID: Target] = [:]
        var people: [UUID: MeetDMCallPerson] = [:]
        let prior = Dictionary(
            targets.map { ($0.value.dmID, ($0.key, $0.value)) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        for recipient in recipients {
            let conversation = Conversation(
                id: recipient.conversationID, kind: .directMessage,
                members: [.init(selfID), recipient.memberID]
            )
            guard recipient.memberID.rawValue != selfID, !recipient.memberID.rawValue.isEmpty,
                  let dmID = MeetCallProbeReport.dmID(for: conversation),
                  seen.insert(dmID).inserted else { continue }
            let previous = prior[dmID]
            let id: UUID = if let previous, previous.1.calleeID == recipient.memberID.rawValue {
                previous.0
            } else {
                UUID()
            }
            updated[id] = Target(
                conversationID: recipient.conversationID, dmID: dmID,
                calleeID: recipient.memberID.rawValue
            )
            people[id] = MeetDMCallPerson(
                id: id, conversationID: recipient.conversationID, memberID: recipient.memberID,
                name: recipient.displayName, email: nil
            )
        }
        targets = updated
        return people
    }

    func incomingPeople() -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: targets.map { ($0.value.dmID, $0.key) })
    }
}

import ChatKit
import SwiftUI

struct ConversationSectionMenu: Equatable {
    struct Destination: Equatable, Identifiable {
        let id: String
        let name: String
    }

    let conversationID: Conversation.ID
    let destinations: [Destination]
    let canRemove: Bool

    init?(conversationID: Conversation.ID, sections: [ConversationSection]) {
        let current = Set(sections.filter { $0.conversationIDs.contains(conversationID) }.map(\.id))
        let destinations = sections.filter { !current.contains($0.id) }.map {
            Destination(id: $0.id, name: $0.name)
        }
        guard !current.isEmpty || !destinations.isEmpty else { return nil }
        self.conversationID = conversationID
        self.destinations = destinations
        canRemove = !current.isEmpty
    }

    @MainActor @ViewBuilder
    func buttons(move: @escaping (ConversationSectionPlacement) -> Void) -> some View {
        if !destinations.isEmpty {
            Menu("Move to Section", systemImage: "folder") {
                ForEach(destinations) { destination in
                    Button(destination.name) {
                        move(ConversationSectionPlacement(
                            conversationID: conversationID,
                            sectionID: destination.id
                        ))
                    }
                }
            }
        }
        if canRemove {
            Button("Remove from Section", systemImage: "folder.badge.minus") {
                move(ConversationSectionPlacement(conversationID: conversationID, sectionID: nil))
            }
        }
    }
}

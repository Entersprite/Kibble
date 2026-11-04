import ChatKit
import SwiftUI

struct CallActivityOverlay: ViewModifier {
    let state: CallActivitiesState?
    @State private var visibleReaction: UUID?
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let reaction = state?.reactions.last, visibleReaction == reaction.id {
                Text(reaction.emoji + " " + reaction.sender).font(.title3).padding(12)
                    .background(.ultraThinMaterial, in: .capsule).padding(.top, 40).padding(.leading, 16)
                    .id(reaction.id)
            }
        }
        .task(id: state?.reactions.last?.id) {
            visibleReaction = state?.reactions.last?.id
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                visibleReaction = nil
            }
        }
    }
}

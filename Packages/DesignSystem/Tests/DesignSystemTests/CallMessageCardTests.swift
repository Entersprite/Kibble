import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// Call history cards are one size, whatever they say: Call missed drew wider
/// than Call ended when each card took its own words' width.
@MainActor
struct CallMessageCardTests {
    @Test func everyCallCardIsTheSameSize() {
        let sizes = CallMessageCard.statuses.map { status in
            NSHostingView(rootView: CallMessageCard(status: status)).fittingSize
        }
        #expect(Set(sizes.map(\.width)).count == 1, "\(sizes)")
        #expect(Set(sizes.map(\.height)).count == 1, "\(sizes)")
    }
}

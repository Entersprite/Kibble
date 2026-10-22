import ChatKit
import SwiftUI

extension EnvironmentValues {
    @Entry var openMessageReference: ((MessageAddress) -> Void)?
}

/// The original is resolved by the account's client, never by a source snapshot.
struct MessageReferenceAction: ViewModifier {
    let source: MessageQuote
    @Environment(\.openMessageReference) private var open

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { activate() }
            .accessibilityActions {
                if MessageAddress(source) != nil, open != nil {
                    Button("Open Original Message") { activate() }
                }
            }
    }

    private func activate() {
        guard let address = MessageAddress(source) else { return }
        open?(address)
    }
}

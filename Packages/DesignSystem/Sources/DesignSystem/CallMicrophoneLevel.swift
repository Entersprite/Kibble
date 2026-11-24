import Foundation
import SwiftUI

@MainActor
public struct CallMicrophoneLevelAction {
    public let id: UUID
    public let isMuted: Bool
    public let read: @MainActor () async -> Double?

    public init(id: UUID, isMuted: Bool, read: @escaping @MainActor () async -> Double?) {
        self.id = id
        self.isMuted = isMuted
        self.read = read
    }
}

struct CallMicrophoneLevelView: View {
    let action: CallMicrophoneLevelAction
    @State private var level: Double?
    @State private var hasSample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Microphone Level")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if action.isMuted {
                Text("Unmute to check your microphone.")
                    .foregroundStyle(.secondary)
            } else if let level {
                ProgressView(value: level)
                    .accessibilityLabel("Microphone level")
            } else if hasSample {
                Text("Microphone level unavailable.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading microphone level")
            }
        }
        .frame(width: 220, alignment: .leading)
        .padding(16)
        .task(id: action.isMuted) { await pollLevel() }
    }

    private func pollLevel() async {
        level = nil
        hasSample = false
        guard !action.isMuted else { return }
        while !Task.isCancelled {
            let sample = await action.read()
            guard !Task.isCancelled else { return }
            level = sample
            hasSample = true
            do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
        }
    }
}

struct CallMicrophoneLevelPopover: ViewModifier {
    let action: CallMicrophoneLevelAction?
    @Binding var request: UUID?

    func body(content: Content) -> some View {
        content.popover(isPresented: isPresented, arrowEdge: .top) {
            if let action, request == action.id {
                CallMicrophoneLevelView(action: action).id(action.id)
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil && request == action?.id },
            set: {
                if !$0 {
                    request = nil
                }
            }
        )
    }
}

import SwiftUI

public struct CalendarSettingsPane: View {
    private let service: String
    private let explanation: String
    private let check: () async -> Bool
    private let setUp: () async -> Bool
    @State private var connected: Bool?
    @State private var attempt = 0
    @State private var settingUp = false

    public init(
        service: String, explanation: String, check: @escaping () async -> Bool,
        setUp: @escaping () async -> Bool
    ) {
        self.service = service
        self.explanation = explanation
        self.check = check
        self.setUp = setUp
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent(service) {
                    switch connected {
                    case true?:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case false?:
                        Label("Couldn’t connect", systemImage: "exclamationmark.circle")
                    case nil:
                        ProgressView().controlSize(.small).accessibilityLabel("Checking Calendar")
                    }
                }
                Button("Check Connection") {
                    connected = nil
                    attempt += 1
                }
                .disabled(connected == nil)
                if connected == false {
                    Button("Set Up Calendar…") {
                        settingUp = true
                    }
                    .disabled(settingUp)
                }
            } footer: {
                Text(explanation)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 250)
        .task(id: attempt) {
            let result = await check()
            if !Task.isCancelled {
                connected = result
            }
        }
        .task(id: settingUp) {
            guard settingUp else { return }
            let ready = await setUp()
            guard !Task.isCancelled else { return }
            settingUp = false
            if ready {
                connected = nil
                attempt += 1
            }
        }
    }
}

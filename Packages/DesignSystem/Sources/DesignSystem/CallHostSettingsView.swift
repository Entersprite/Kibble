import ChatKit
import SwiftUI

extension CallActivitiesView {
    @ViewBuilder func hostControls(submit: @escaping (CallActivity) -> Void) -> some View {
        if let settings = scene.state.hostSettings {
            CallHostSettingsView(
                settings: settings,
                availableActions: scene.state.availableActions,
                submit: submit
            )
        }
    }
}

private struct CallHostSettingsView: View {
    let settings: CallHostSettings
    let availableActions: [String]
    let submit: (CallActivity) -> Void

    var body: some View {
        Divider()
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Host Controls").font(.headline)
                Spacer()
                if availableActions.contains("endConference") {
                    EndConferenceButton { submit(CallActivity("endConference")) }
                }
            }
            Toggle("Host Management", isOn: Binding(
                get: { settings.managementEnabled },
                set: { submit(CallActivity("hostManagement", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("hostManagement"))
            if let access = settings.meetingAccess {
                meetingAccessControl(access)
                if let allowed = access.joinRequestsAllowed, availableActions.contains("allowJoinRequests") {
                    Toggle("Let people ask to join", isOn: Binding(
                        get: { allowed },
                        set: { submit(CallActivity("allowJoinRequests", enabled: $0)) }
                    ))
                    .help("This setting can apply to future uses of this meeting link.")
                }
            }
            if let enabled = settings.waitingRoomEnabled {
                LabeledContent(
                    "Waiting room",
                    value: enabled ? String(localized: "On") : String(localized: "Off")
                )
            }
            if settings.waitingRoomEnabled != true, let allowed = settings.joiningBeforeHostAllowed,
               availableActions.contains("allowJoiningBeforeHost") {
                Toggle("Host must join before anyone else", isOn: Binding(
                    get: { !allowed },
                    set: { submit(CallActivity("allowJoiningBeforeHost", enabled: !$0)) }
                ))
                .help("This setting can apply to future uses of this meeting link.")
            }
            if settings.microphoneAllowed != nil || settings.cameraAllowed != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { sharedPolicyToggles }
                    VStack(alignment: .leading, spacing: 5) { sharedPolicyToggles }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { captureToggles }
                    VStack(alignment: .leading, spacing: 5) { captureToggles }
                }
            } else {
                sharedPolicyToggles
            }
            Toggle("Allow participants to send reactions", isOn: Binding(
                get: { settings.reactionsAllowed },
                set: { submit(CallActivity("allowReactions", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("allowReactions"))
        }
    }

    @ViewBuilder private func meetingAccessControl(_ access: CallMeetingAccess) -> some View {
        if let current = AccessPreset(rawValue: access.preset) {
            let options = AccessPreset.allCases.filter { access.availablePresets.contains($0.rawValue) }
            if availableActions.contains("setMeetingAccess"), options.contains(where: { $0 != current }) {
                Picker("Meeting access type", selection: Binding(
                    get: { current },
                    set: { submit(CallActivity("setMeetingAccess", options: [$0.rawValue])) }
                )) {
                    ForEach(
                        AccessPreset.allCases.filter { $0 == current || options.contains($0) },
                        id: \.self
                    ) {
                        $0.title.tag($0).disabled(!options.contains($0))
                    }
                }
                .pickerStyle(.menu)
                .help("This setting can apply to future uses of this meeting link.")
            } else {
                LabeledContent { current.title } label: { Text("Meeting access type") }
            }
        }
    }

    private enum AccessPreset: String, CaseIterable {
        case open, trusted, restricted

        var title: Text {
            switch self {
            case .open: Text("Open")
            case .trusted: Text("Trusted")
            case .restricted: Text("Restricted")
            }
        }
    }

    @ViewBuilder private var sharedPolicyToggles: some View {
        if let allowed = settings.chatMessagesAllowed {
            Toggle("Let participants send messages", isOn: Binding(
                get: { allowed },
                set: { submit(CallActivity("allowChatMessages", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("allowChatMessages"))
            .help("This setting can apply to future uses of this meeting link.")
        }
        if let allowed = settings.screenSharingAllowed {
            Toggle("Let participants share their screen", isOn: Binding(
                get: { allowed },
                set: { submit(CallActivity("allowScreenSharing", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("allowScreenSharing"))
            .help("This setting can apply to future uses of this meeting link.")
        }
    }

    @ViewBuilder private var captureToggles: some View {
        if let allowed = settings.microphoneAllowed {
            Toggle("Let participants use their microphone", isOn: Binding(
                get: { allowed },
                set: { submit(CallActivity("allowMicrophone", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("allowMicrophone"))
        }
        if let allowed = settings.cameraAllowed {
            Toggle("Let participants use their camera", isOn: Binding(
                get: { allowed },
                set: { submit(CallActivity("allowCamera", enabled: $0)) }
            ))
            .disabled(!availableActions.contains("allowCamera"))
        }
    }
}

private struct EndConferenceButton: View {
    let endMeeting: () -> Void
    @State private var confirmsEnd = false

    var body: some View {
        Button("End Meeting for Everyone…", role: .destructive) {
            confirmsEnd = true
        }
        .alert("End meeting for everyone?", isPresented: $confirmsEnd) {
            Button("Cancel", role: .cancel) {}
            Button("End Meeting", role: .destructive, action: endMeeting)
        } message: {
            Text("Everyone will be disconnected from this meeting.")
        }
    }
}

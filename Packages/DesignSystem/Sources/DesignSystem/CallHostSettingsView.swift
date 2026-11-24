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

/// What the meeting's host decides for everyone: who gets in and how, then
/// what participants may do, then ending the meeting.
///
/// Sections of labeled rows, so the view reads as settings whether its
/// container is a form or a plain stack. Each row shows the confirmed value;
/// a row whose action the call does not offer is disabled, not hidden, when
/// its value is known. Settings saved with the meeting link say so once, in
/// the section's footer, rather than in a tooltip on each.
struct CallHostSettingsView: View {
    let settings: CallHostSettings
    let availableActions: [String]
    let submit: (CallActivity) -> Void

    static let linkNote = "Some of these settings also apply to later meetings that use this link."

    var body: some View {
        Section {
            Toggle("Host Management", isOn: Binding(
                get: { settings.managementEnabled },
                set: { submit(CallActivity("hostManagement", enabled: $0)) }
            ))
            .disabled(!offers("hostManagement"))
            if let access = settings.meetingAccess {
                meetingAccessControl(access)
                if let allowed = access.joinRequestsAllowed, offers("allowJoinRequests") {
                    Toggle("Let People Ask to Join", isOn: Binding(
                        get: { allowed },
                        set: { submit(CallActivity("allowJoinRequests", enabled: $0)) }
                    ))
                }
            }
            if let enabled = settings.waitingRoomEnabled {
                LabeledContent("Waiting Room") { enabled ? Text("On") : Text("Off") }
            }
            if settings.waitingRoomEnabled != true, let allowed = settings.joiningBeforeHostAllowed,
               offers("allowJoiningBeforeHost") {
                Toggle("Host Must Join First", isOn: Binding(
                    get: { !allowed },
                    set: { submit(CallActivity("allowJoiningBeforeHost", enabled: !$0)) }
                ))
            }
        } header: {
            Text("Host Controls")
        }
        Section {
            participantToggles
        } header: {
            Text("Participants Can")
        } footer: {
            Text(Self.linkNote)
        }
        if offers("endConference") {
            Section {
                EndConferenceButton { submit(CallActivity("endConference")) }
            }
        }
    }

    @ViewBuilder private var participantToggles: some View {
        if let allowed = settings.chatMessagesAllowed {
            policyToggle("Send Messages", isOn: allowed, action: "allowChatMessages")
        }
        if let allowed = settings.screenSharingAllowed {
            policyToggle("Share Their Screen", isOn: allowed, action: "allowScreenSharing")
        }
        if let allowed = settings.microphoneAllowed {
            policyToggle("Use Their Microphone", isOn: allowed, action: "allowMicrophone")
        }
        if let allowed = settings.cameraAllowed {
            policyToggle("Use Their Camera", isOn: allowed, action: "allowCamera")
        }
        policyToggle("Send Reactions", isOn: settings.reactionsAllowed, action: "allowReactions")
    }

    private func policyToggle(_ title: String, isOn: Bool, action: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { submit(CallActivity(action, enabled: $0)) }
        ))
        .disabled(!offers(action))
        .accessibilityLabel("Participants can \(title.lowercased())")
    }

    @ViewBuilder private func meetingAccessControl(_ access: CallMeetingAccess) -> some View {
        if let current = AccessPreset(rawValue: access.preset) {
            let options = AccessPreset.allCases.filter { access.availablePresets.contains($0.rawValue) }
            if offers("setMeetingAccess"), options.contains(where: { $0 != current }) {
                Picker("Meeting Access", selection: Binding(
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
            } else {
                LabeledContent("Meeting Access") { current.title }
            }
        }
    }

    private func offers(_ action: String) -> Bool {
        availableActions.contains(action)
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
}

private struct EndConferenceButton: View {
    let endMeeting: () -> Void
    @State private var confirmsEnd = false

    var body: some View {
        Button("End Meeting for Everyone…", role: .destructive) {
            confirmsEnd = true
        }
        .alert("End this meeting for everyone?", isPresented: $confirmsEnd) {
            Button("End Meeting", role: .destructive, action: endMeeting)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone is disconnected, and the meeting ends.")
        }
    }
}

import ChatKit
import SwiftUI

/// Everyone else in the call, for the People control and the strip's "+N".
struct CallPeopleList: View {
    let entries: [CallRosterEntry]?
    var activities: CallActivitiesScene?
    var pinTargets: [CallParticipantDevice]?
    var personalVideo: CallPersonalVideoControls?
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var confirmation: Confirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In This Call").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if offers("muteAllParticipants"),
                   entries?.contains(where: { $0.microphoneMuted != true }) == true {
                    Button("Mute All…") { confirmation = .muteAll }
                        .disabled(operation != nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if let personalVideo {
                personalVideo
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            if offers("setPinForEveryone"), let pinTargets {
                CallPinsForEveryoneMenu(
                    devices: pinTargets, limit: activities?.state.sharedPinLimit, busy: operation != nil
                ) { device, name in
                    if device.isPinnedForEveryone == true {
                        confirmation = .clearSharedPin(device.id, name: name)
                    } else {
                        perform(CallActivity("setPinForEveryone", resourceID: device.id))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            let waiting = activities?.peopleWaiting ?? []
            let invited = activities?.state.agendaGuests ?? []
            if entries?.isEmpty == false || !waiting.isEmpty || !invited.isEmpty {
                ScrollView {
                    peopleRows(waiting: waiting, invited: invited)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            } else {
                Text(entries == nil ? "Who’s in the call isn’t known yet." : "Nobody else has joined yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 260, alignment: .leading)
        .alert(confirmation?.title ?? "", isPresented: showsConfirmation, presenting: confirmation) { value in
            Button("Cancel", role: .cancel) {}
            Button(value.button, role: value.role) { perform(value.activity) }
        } message: { value in
            Text(value.message)
        }
        .onDisappear { operation?.cancel() }
    }

    private func peopleRows(waiting: [CallWaitingParticipant], invited: [CallAgendaGuest]) -> some View {
        let joined = entries ?? []
        let raised = CallRoster.raisedHands(joined)
        return VStack(alignment: .leading, spacing: 2) {
            if !raised.isEmpty {
                HStack {
                    Text("Raised Hands").font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if offers("lowerAllHands") {
                        Button("Lower All…") { confirmation = .lowerAllHands }
                            .disabled(operation != nil)
                    }
                }
                .padding(8)
                ForEach(raised) { entry in
                    row(entry)
                }
                if !waiting.isEmpty || joined.contains(where: { !$0.handRaised }) {
                    Divider()
                }
            }
            if !waiting.isEmpty {
                CallWaitingPeopleSection(
                    participants: waiting, busy: operation != nil,
                    canRespondInBulk: offers("respondToAdmissions"),
                    perform: perform, confirmDenial: { confirmation = .denyAdmissions($0) }
                )
            }
            ForEach(joined.filter { !$0.handRaised }) { entry in
                row(entry)
            }
            if !invited.isEmpty {
                if !waiting.isEmpty || !joined.isEmpty {
                    Divider()
                }
                CallAgendaGuestSection(guests: invited, busy: operation != nil, openChat: guestChatAction)
            }
        }
    }

    private var showsConfirmation: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: {
            if !$0 {
                confirmation = nil
            }
        })
    }

    private func row(_ entry: CallRosterEntry) -> some View {
        HStack(spacing: 8) {
            participant(entry)
            lowerHandButton(entry)
            let cohost = offers("setCohost") ? entry.cohostChange : nil
            let canMute = offers("muteParticipant") && entry.microphoneMuted != true
            let canRemove = offers("removeParticipant")
            let canSendToWaitingRoom = entry.canSendToWaitingRoom && offers("sendParticipantToWaitingRoom")
            let canBlock = entry.canBlockInMeeting && offers("blockParticipant")
            if cohost != nil || canMute || canRemove || canSendToWaitingRoom || canBlock {
                Menu {
                    if canMute {
                        Button("Mute Microphone", systemImage: "mic.slash") {
                            perform(CallActivity("muteParticipant", resourceID: entry.id))
                        }
                    }
                    if let cohost {
                        Button(cohost ? "Make co-host" : "Remove co-host role") {
                            perform(CallActivity("setCohost", resourceID: entry.id, enabled: cohost))
                        }
                    }
                    if canRemove {
                        Button(role: .destructive) { confirmation = .remove(entry) } label: {
                            Label("Remove from Call…", systemImage: "person.fill.xmark")
                        }
                    }
                    if canSendToWaitingRoom {
                        Button { confirmation = .sendToWaitingRoom(entry) } label: {
                            Label("Send to Waiting Room…", systemImage: "arrow.turn.up.left")
                        }
                    }
                    if canBlock {
                        Button(role: .destructive) { confirmation = .block(entry) } label: {
                            Label("Block from This Meeting…", systemImage: "hand.raised.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(entry.name)")
                .disabled(operation != nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder private func lowerHandButton(_ entry: CallRosterEntry) -> some View {
        if entry.handRaised, offers("lowerParticipantHand") {
            Button("Lower hand for \(entry.name)", systemImage: "hand.raised.slash") {
                perform(CallActivity("lowerParticipantHand", resourceID: entry.id))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Lower Hand")
            .disabled(operation != nil)
        }
    }

    private func participant(_ entry: CallRosterEntry) -> some View {
        HStack(spacing: 10) {
            MonogramCircle(size: 26) {
                Text(CallRosterFace.initials(entry.name)).font(.system(size: 10, weight: .semibold))
            }
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            if let role = Self.label(for: entry.role) {
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
            if entry.isPresenting {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .help("Sharing their screen")
            }
            if entry.isPinnedForEveryone {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).help("Pinned for everyone")
            }
            if CallRoster.showsMuted(entry) {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.secondary)
                    .help("Muted")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: entry))
    }

    private func offers(_ action: String) -> Bool {
        activities?.state.availableActions.contains(action) == true
    }

    private func perform(_ activity: CallActivity) {
        guard operation == nil, offers(activity.action), let activities else { return }
        run(failureMessage: Self.failureMessage(for: activity.action)) {
            try await activities.perform(activity)
        }
    }

    private func openGuestChat(_ guest: UUID) {
        guard operation == nil, let open = activities?.openGuestChat else { return }
        run(failureMessage: "The guest’s direct conversation could not be opened.") { try await open(guest) }
    }

    private var guestChatAction: ((UUID) -> Void)? {
        guard activities?.openGuestChat != nil else { return nil }
        return { openGuestChat($0) }
    }

    private func run(failureMessage: String, action: @escaping @MainActor () async throws -> Void) {
        failure = nil
        operation = Task {
            defer { operation = nil }
            do {
                try await action()
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    failure = failureMessage
                }
            }
        }
    }

    private static func failureMessage(for action: String) -> String {
        switch action {
        case "muteAllParticipants": "Some mute requests could not be confirmed."
        case "muteParticipant": "The mute request could not be confirmed."
        case "lowerParticipantHand", "lowerAllHands": "The raised hands could not be updated."
        case "removeParticipant": "The removal could not be confirmed."
        case "blockParticipant": "The block could not be confirmed."
        case "setPinForEveryone": "The shared pin could not be confirmed."
        case "sendParticipantToWaitingRoom": "The move to the waiting room could not be confirmed."
        case "respondToAdmission": "The response could not be confirmed."
        case "respondToAdmissions": "Some responses could not be confirmed."
        default: "The co-host change could not be confirmed."
        }
    }

    private static func label(for role: CallParticipantRole?) -> String? {
        switch role {
        case .host: "Host"
        case .cohost: "Co-host"
        default: nil
        }
    }

    /// Name, then only what is reported: a muted microphone, a shared screen.
    static func label(for entry: CallRosterEntry) -> String {
        var parts = [entry.name]
        if let role = label(for: entry.role) {
            parts.append(role)
        }
        if entry.handRaised {
            parts.append("hand raised")
        }
        if CallRoster.showsMuted(entry) {
            parts.append("muted")
        }
        if entry.isPresenting {
            parts.append("sharing their screen")
        }
        if entry.isPinnedForEveryone {
            parts.append("pinned for everyone")
        }
        return parts.joined(separator: ", ")
    }
}

private struct Confirmation {
    let title: String
    let message: String
    let button: String
    var role: ButtonRole?
    let activity: CallActivity

    static let muteAll = Confirmation(
        title: "Mute everyone else?", message: "Participants can unmute themselves.",
        button: "Mute All", activity: CallActivity("muteAllParticipants")
    )

    static let lowerAllHands = Confirmation(
        title: "Lower all raised hands?", message: "This clears the meeting’s raised hands.",
        button: "Lower All", activity: CallActivity("lowerAllHands")
    )

    static func remove(_ entry: CallRosterEntry) -> Confirmation {
        Confirmation(
            title: "Remove \(entry.name)?", message: "They’ll be disconnected from this call.",
            button: "Remove", role: .destructive,
            activity: CallActivity("removeParticipant", resourceID: entry.id)
        )
    }

    static func sendToWaitingRoom(_ entry: CallRosterEntry) -> Confirmation {
        Confirmation(
            title: "Send \(entry.name) to the waiting room?",
            message: "They’ll leave the call until a host brings them back.",
            button: "Send to Waiting Room", role: .destructive,
            activity: CallActivity("sendParticipantToWaitingRoom", resourceID: entry.id)
        )
    }

    static func block(_ entry: CallRosterEntry) -> Confirmation {
        Confirmation(
            title: "Block \(entry.name) from this meeting?",
            message: "They’ll be removed and will need a new invitation to rejoin.",
            button: "Block", role: .destructive,
            activity: CallActivity("blockParticipant", resourceID: entry.id)
        )
    }

    static func denyAdmissions(_ ids: [UUID]) -> Confirmation {
        var activity = CallActivity("respondToAdmissions", enabled: false)
        activity.participantIDs = ids
        return Confirmation(
            title: "Deny all join requests?", message: "This applies to the people asking to join now.",
            button: "Deny All", role: .destructive, activity: activity
        )
    }

    static func clearSharedPin(_ id: UUID, name: String) -> Confirmation {
        Confirmation(
            title: "Unpin \(name) for everyone?",
            message: "Participants can still pin this tile for themselves.",
            button: "Unpin", activity: CallActivity("setPinForEveryone", resourceID: id, enabled: false)
        )
    }
}

/// The People control in a conversation call's bar: the list in a popover.
struct CallPeopleButton: View {
    let entries: [CallRosterEntry]?
    @Binding var isPresented: Bool
    var activities: CallActivitiesScene?
    var pinTargets: [CallParticipantDevice]?
    var personalVideo: CallPersonalVideoControls?

    var body: some View {
        let waiting = activities?.peopleWaiting.count ?? 0
        CallRoundButton(
            title: waiting == 0 ? "People" : "People, \(waiting) waiting",
            symbol: "person.2.fill"
        ) {
            isPresented.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if waiting > 0 {
                Text(waiting.formatted())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.tint, in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            CallPeopleList(
                entries: entries, activities: activities, pinTargets: pinTargets, personalVideo: personalVideo
            )
        }
    }
}

private extension CallActivitiesScene {
    var peopleWaiting: [CallWaitingParticipant] {
        state.availableActions.contains("respondToAdmission") ? state.waitingParticipants : []
    }
}

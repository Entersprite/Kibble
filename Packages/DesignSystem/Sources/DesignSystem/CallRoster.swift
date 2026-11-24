import ChatKit
import SwiftUI

/// Someone else in the call, as the window lists them: one of the devices the
/// provider reports, never a directory member. One person on two devices is
/// two entries; a shared screen is not an entry but marks the device sharing it.
struct CallRosterEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Nil is unknown, never muted.
    let microphoneMuted: Bool?
    let isPresenting: Bool
    var handRaised = false
    var handRaisedAt: Date?
    var isSpeaking = false
    var role: CallParticipantRole?
    var canSendToWaitingRoom = false
    var canBlockInMeeting = false
    var isPinnedForEveryone = false

    var cohostChange: Bool? {
        switch role {
        case .participant: true
        case .cohost: false
        default: nil
        }
    }
}

enum CallRoster {
    /// Nil while the roster is not established, which is not the same as
    /// nobody else being there. This device and presentations are left out.
    static func entries(_ devices: [CallParticipantDevice]?) -> [CallRosterEntry]? {
        guard let devices else { return nil }
        let presenting = Set(devices.filter(\.isPresentation).compactMap(\.parentID))
        return devices.filter { !$0.isPresentation && !$0.isLocal }
            .map { device in
                CallRosterEntry(
                    id: device.id, name: name(of: device), microphoneMuted: device.microphoneMuted,
                    isPresenting: presenting.contains(device.id), handRaised: device.handRaised == true,
                    handRaisedAt: device.handRaisedAt,
                    isSpeaking: device.isSpeaking == true, role: device.role,
                    canSendToWaitingRoom: device.canSendToWaitingRoom == true,
                    canBlockInMeeting: device.canBlockInMeeting == true,
                    isPinnedForEveryone: device.isPinnedForEveryone == true
                )
            }
            // By name, so a roster update in another order does not shuffle the window.
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                guard order == .orderedSame else { return order == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func raisedHands(_ entries: [CallRosterEntry]) -> [CallRosterEntry] {
        entries.filter(\.handRaised).sorted { first, second in
            (first.handRaisedAt ?? .distantFuture) < (second.handRaisedAt ?? .distantFuture)
        }
    }

    static func name(of device: CallParticipantDevice) -> String {
        let name = device.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Participant" : name
    }

    /// The line under a conversation call's name once connected; nil says
    /// nothing, for a roster nobody has reported.
    static func summary(_ entries: [CallRosterEntry]?) -> String? {
        guard let entries else { return nil }
        switch entries.count {
        case 0: return "Waiting for others to join"
        case 1: return "With \(entries[0].name)"
        case 2: return "With \(entries[0].name) and \(entries[1].name)"
        default: return "With \(entries[0].name) and \(entries.count - 1) others"
        }
    }

    /// Whether this device's own microphone shows as muted: only a report of
    /// muted does, so an unknown never draws the badge.
    static func showsMuted(_ entry: CallRosterEntry) -> Bool {
        entry.microphoneMuted == true
    }

    /// A camera's owner, muted by report; a shared screen carries no microphone.
    static func isMuted(_ video: CallRemoteVideo, in roster: [CallRosterEntry]?) -> Bool {
        guard let id = video.participantID, !video.isScreen else { return false }
        return roster?.first(where: { $0.id == id }).map(showsMuted) ?? false
    }
}

/// The avatar, name and status of a call in a group or space: the
/// conversation's own picture, and who else is in it underneath.
struct CallConversationHeader: View {
    let call: AudioCallSession
    let conversation: Conversation?
    let roster: [CallRosterEntry]?
    let timing: CallTiming
    var accountLabel: String?
    var avatarSize: CGFloat = 96
    var isPreparingMeeting = false
    var preparationPreview: AnyView?
    let showPeople: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            picture
                .background {
                    if !isPreparingMeeting, AudioCallPresentation.isWaiting(call.phase) {
                        // `ConversationPicture`'s own corner for a space's tile.
                        CallWaitingHalo(
                            size: avatarSize,
                            cornerRadius: conversation?.kind == .space ? avatarSize * 0.26 : nil
                        )
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .accessibilityHidden(preparationPreview == nil)
            VStack(spacing: 5) {
                Text(call.displayName)
                    .font(.title.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if isPreparingMeeting {
                        Text("Ready to join?")
                    } else {
                        CallStatusText(call: call, timing: timing)
                    }
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                if let accountLabel {
                    Text(accountLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("On \(accountLabel)")
                }
                if let message = AudioCallPresentation.failureMessage(for: call) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                        .padding(.top, 6)
                }
            }
            if call.phase == .connected, let roster {
                CallRosterStrip(entries: roster, showPeople: showPeople)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var picture: some View {
        if let preparationPreview {
            preparationPreview
                .frame(width: 256, height: 144)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel("Camera preview")
        } else if let conversation {
            ConversationPicture(conversation: conversation, size: avatarSize)
        } else {
            MonogramCircle(size: avatarSize) {
                Image(systemName: "person.3.fill").font(.system(size: avatarSize * 0.36))
            }
        }
    }
}

/// Up to four of the others in the call, a "+N" for the rest, or the wait
/// for anyone at all. The faces are initials on the monogram disc: a call's
/// devices carry a name and nothing else.
struct CallRosterStrip: View {
    static let shown = 4
    static let faceWidth: CGFloat = 56
    let entries: [CallRosterEntry]
    let showPeople: (() -> Void)?

    var body: some View {
        if entries.isEmpty {
            Text(CallRoster.summary(entries) ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(entries.prefix(Self.shown)) { entry in
                    CallRosterFace(entry: entry)
                }
                if entries.count > Self.shown {
                    Button {
                        showPeople?()
                    } label: {
                        VStack(spacing: 6) {
                            MonogramCircle(size: 44) {
                                Text("+\(entries.count - Self.shown)")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text("More").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: Self.faceWidth)
                    }
                    .buttonStyle(.plain)
                    .disabled(showPeople == nil)
                    .accessibilityLabel("\(entries.count - Self.shown) more people")
                    .help("Show everyone in the call")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(CallRoster.summary(entries) ?? "People in the call")
        }
    }
}

/// One person's disc, name and microphone.
struct CallRosterFace: View {
    let entry: CallRosterEntry

    var body: some View {
        VStack(spacing: 6) {
            MonogramCircle(size: 44) {
                Text(CallRosterFace.initials(entry.name))
                    .font(.system(size: 16, weight: .semibold))
            }
            .overlay(alignment: .bottomTrailing) {
                if entry.handRaised {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
                        .accessibilityLabel("Hand raised")
                }
                if CallRoster.showsMuted(entry) {
                    CallRemoteMutedBadge(size: 18)
                        .offset(x: 3, y: 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            Text(entry.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Fixed, so four faces and a "+N" always fit the audio column.
        .frame(width: CallRosterStrip.faceWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CallPeopleList.label(for: entry))
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func handleActivityChannelClosed(_ channel: String) async {
        guard let activity = MeetMediaSessionWire.ActivityChannel(rawValue: channel),
              activity == .captions || activity == .messages else { return }
        assignedActivityChannels?.remove(activity)
        if activity == .captions {
            resetCaptions()
        }
        updateActivityAvailability()
        await receiveActivities?(activities)
    }

    func resetCaptions() {
        captionTransport = NativeMeetCaptionTransport()
        activities.captions = nil
        activities.captionLanguages = nil
    }

    func updateDeviceCaptionLanguages(_ languages: MeetCaptionWire.Languages?) async {
        guard !closed, let languages, !languages.isEmpty else { return }
        var changed = activities.recordingCaptionLanguages != languages.live
        activities.recordingCaptionLanguages = languages.live
        if assignedActivityChannels?.contains(.captions) == true {
            captionTransport.deviceLanguages = CallCaptionLanguages(
                live: languages.live, translations: languages.translations
            )
            changed = adoptCaptionLanguages() || changed
        }
        if changed {
            await receiveActivities?(activities)
        }
    }

    private func adoptCaptionLanguages() -> Bool {
        let stream = captionTransport.isSubscribed ? captionTransport.streamLanguages : nil
        let languages = stream ?? captionTransport.deviceLanguages
        guard languages != activities.captionLanguages else { return false }
        activities.captionLanguages = languages
        return true
    }

    func configureCaptions(_ activity: CallActivity, sequence: UInt64) async throws {
        let label = MeetMediaSessionWire.ActivityChannel.captions.rawValue
        guard activity.enabled else {
            guard captionTransport.isSubscribed else { return }
            let command = try MeetCaptionWire.disable(sequence: sequence)
            try await sendCaptionCommand(command, kind: .configure, sequence: sequence, channel: label)
            captionTransport.updates = NativeMeetCaptionUpdates()
            activities.captions = nil
            await receiveActivities?(activities)
            return
        }
        guard activity.options.count == 2 else {
            throw ChatError.decoding("Choose a meeting language and a caption language.")
        }
        let spoken = activity.options[0], display = activity.options[1]
        try validateCaptionLanguages(spoken: spoken, display: display)
        let configurationSequence = captionTransport.isSubscribed ? sequence : sequence + 1
        let command = try MeetCaptionWire.configure(
            spokenLanguage: spoken, displayLanguage: display, sequence: configurationSequence
        )
        if !captionTransport.isSubscribed {
            activitySequence = configurationSequence
            try await subscribeToCaptions(sequence: sequence, channel: label)
            try await check()
            try validateCaptionLanguages(spoken: spoken, display: display)
        }
        captionTransport.pending = NativeMeetCaptionUpdates()
        defer { captionTransport.pending = nil }
        try await sendCaptionCommand(
            command,
            kind: .configure,
            sequence: configurationSequence,
            channel: label
        )
        if let pending = captionTransport.pending {
            captionTransport.updates = pending
        }
        activities.captions = CallCaptionState(
            spokenLanguage: spoken, displayLanguage: display, segments: captionTransport.updates.visible
        )
        await receiveActivities?(activities)
    }

    private func validateCaptionLanguages(spoken: String, display: String) throws {
        guard activities.captionLanguages?.supports(spoken: spoken, display: display) != false else {
            throw ChatError.unknown("That caption language choice is unavailable in this meeting.")
        }
    }

    private func subscribeToCaptions(sequence: UInt64, channel: String) async throws {
        captionTransport.isSubscribing = true
        defer {
            captionTransport.isSubscribing = false
            if !captionTransport.isSubscribed {
                captionTransport.settingsVersion = nil
                captionTransport.streamLanguages = nil
            }
        }
        let response = try await sendCaptionCommand(
            MeetCaptionWire.subscribe(sequence: sequence), kind: .subscribe, sequence: sequence,
            channel: channel
        )
        captionTransport.isSubscribed = true
        let settings = (try? MeetCaptionWire.updates(response).settings) ?? []
        if settings.contains(where: { update in
            captionTransport.settingsVersion.map { update.version > $0 } ?? true
        }) {
            await receiveCaptionData(response)
        } else if adoptCaptionLanguages() {
            await receiveActivities?(activities)
        }
    }

    func receiveCaptionData(_ data: Data) async {
        guard captionTransport.isSubscribed || captionTransport.isSubscribing,
              let updates = try? MeetCaptionWire.updates(data) else { return }
        let settings = captionTransport.acceptSettings(updates.settings)
        let languageChanged = adoptCaptionLanguages()
        let captions = applyCaptionUpdates(updates.captions)
        if languageChanged || captions.changed {
            await receiveActivities?(activities)
        }
        let receipt = MeetCaptionWire.acknowledgeSettings(settings) + MeetCaptionWire
            .acknowledge(captions.resources)
        guard ready, !closed, !receipt.isEmpty else { return }
        try? await media.sendActivityData(
            channel: MeetMediaSessionWire.ActivityChannel.captions.rawValue, data: receipt
        )
    }

    private func applyCaptionUpdates(
        _ changes: [MeetCaptionWire.Change]
    ) -> (changed: Bool, resources: [MeetCaptionWire.Resource]) {
        guard !changes.isEmpty, captionTransport.pending != nil || activities.captions != nil
        else { return (false, []) }
        let devices = participantDevices
        let speakerName = { Self.captionSpeaker($0, in: devices) }
        if var pending = captionTransport.pending {
            let resources = pending.apply(changes, speakerName: speakerName)
            captionTransport.pending = pending
            return (false, resources)
        }
        let resources = captionTransport.updates.apply(changes, speakerName: speakerName)
        let visible = captionTransport.updates.visible
        let changed = activities.captions?.segments != visible
        activities.captions?.segments = visible
        return (changed, resources)
    }

    private static func captionSpeaker(
        _ reference: String, in devices: [String: MeetDeviceWire.Device]
    ) -> String? {
        if let device = devices[reference] {
            return device.displayName
        }
        let matches = devices.values.filter { $0.name.hasSuffix("/devices/" + reference) }
        return matches.count == 1 ? matches.first?.displayName : nil
    }

    @discardableResult
    private func sendCaptionCommand(
        _ data: Data, kind: MeetCaptionWire.Command, sequence: UInt64, channel: String
    ) async throws -> Data {
        let response = try await media.exchangeActivityData(channel: channel, data: data) {
            MeetCaptionWire.matches($0, command: kind, sequence: sequence)
        }
        try await check()
        guard assignedActivityChannels?.contains(.captions) == true else {
            throw ChatError.unsupported(capability: "meetingCaptions")
        }
        try MeetCaptionWire.confirm(response, command: kind, sequence: sequence)
        return response
    }
}

struct NativeMeetCaptionTransport {
    var isSubscribing = false
    var isSubscribed = false
    var pending: NativeMeetCaptionUpdates?
    var updates = NativeMeetCaptionUpdates()
    var settingsVersion: UInt64?
    var streamLanguages: CallCaptionLanguages?
    var deviceLanguages: CallCaptionLanguages?

    mutating func acceptSettings(_ settings: [MeetCaptionWire.Settings]) -> [UInt64] {
        var versions: [UInt64] = []
        for update in settings {
            if let settingsVersion, update.version < settingsVersion {
                continue
            }
            if update.version != settingsVersion {
                settingsVersion = update.version
                streamLanguages = update.languages.isEmpty ? nil : CallCaptionLanguages(
                    live: update.languages.live, translations: update.languages.translations
                )
            }
            versions.append(update.version)
        }
        return versions
    }
}

struct NativeMeetCaptionUpdates {
    private struct Entry {
        let version: UInt64
        let finalized: Bool
        let segmentID: UUID
    }

    private var entries: [UInt64: Entry] = [:]
    private var order: [UInt64] = []
    private(set) var visible: [CallCaptionSegment] = []

    mutating func apply(
        _ changes: [MeetCaptionWire.Change], speakerName: (String) -> String?
    ) -> [MeetCaptionWire.Resource] {
        var acknowledgements: [MeetCaptionWire.Resource] = []
        for change in changes {
            let resource = change.resource
            let previous = entries[resource.id]
            if previous?.version == resource.version {
                acknowledgements.append(resource)
                continue
            }
            if let previous, previous.finalized || previous.version > resource.version {
                continue
            }
            let id = previous?.segmentID ?? UUID()
            switch change {
            case let .caption(caption):
                entries[resource.id] = Entry(
                    version: resource.version,
                    finalized: caption.isFinal,
                    segmentID: id
                )
                if caption.text.isEmpty {
                    visible.removeAll { $0.id == id }
                } else {
                    let segment = CallCaptionSegment(
                        id: id,
                        speaker: speakerName(caption.speaker),
                        text: caption.text
                    )
                    if let index = visible.firstIndex(where: { $0.id == id }) {
                        visible[index] = segment
                    } else {
                        visible.append(segment)
                    }
                }
            case .deletion:
                entries[resource.id] = Entry(version: resource.version, finalized: true, segmentID: id)
                visible.removeAll { $0.id == id }
            }
            if previous == nil {
                order.append(resource.id)
            }
            acknowledgements.append(resource)
        }
        for id in order.prefix(max(0, order.count - 256)) {
            entries[id] = nil
        }
        order = Array(order.suffix(256))
        visible = Array(visible.suffix(3))
        return acknowledgements
    }
}

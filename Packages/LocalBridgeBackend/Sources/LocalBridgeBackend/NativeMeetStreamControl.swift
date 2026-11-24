import Foundation
import GChatBridgeCore

enum NativeMeetStreamControl {
    static func configure(
        _ media: any CallMediaEngine, from configuration: Data
    ) async throws -> CallStreamControlChannel? {
        guard await media.supportsStreamControl else { return nil }
        let channel = try MeetMediaSessionWire.streamControlChannel(serverConfiguration: configuration)
        let options = channel.map(mediaOptions)
        try await media.configureStreamControl(options)
        return options
    }

    static func configureActivities(
        _ media: any CallMediaEngine, from configuration: Data, allowsGzipCaptions: Bool
    ) async -> Set<MeetMediaSessionWire.ActivityChannel> {
        let channels = (try? MeetMediaSessionWire.activityChannels(
            serverConfiguration: configuration, allowsGzipCaptions: allowsGzipCaptions
        )) ?? [:]
        var assigned: Set<MeetMediaSessionWire.ActivityChannel> = []
        for (activity, channel) in channels {
            guard !Task.isCancelled else { return [] }
            do {
                try await media.configureActivityChannel(mediaOptions(channel), label: activity.rawValue)
                assigned.insert(activity)
            } catch {
                continue
            }
        }
        return assigned
    }

    private static func mediaOptions(_ channel: MeetMediaSessionWire
        .StreamControlChannel) -> CallStreamControlChannel {
        CallStreamControlChannel(
            id: channel.id, isOrdered: channel.ordered,
            maxPacketLifeTime: channel.maxPacketLifeTime, maxRetransmits: channel.maxRetransmits,
            compression: channel.compression == .gzip ? .gzip : .none
        )
    }

    static func reliabilityLabel(_ channel: CallStreamControlChannel) -> String {
        if channel.maxPacketLifeTime != nil {
            return "maximum packet lifetime"
        }
        if channel.maxRetransmits != nil {
            return "maximum retransmissions"
        }
        return "fully reliable"
    }
}

extension NativeMeetCallSession {
    func createPrimaryMediaSession(_ configuration: Data) async throws -> MeetMediaSessionWire.Session {
        let requestActivities = await media.supportsActivityChannelAssignments
        let allowsGzipCaptions = await media.supportsGzipActivityChannels
        let offered = requestActivities ? MeetMediaSessionWire.requestingActivityChannels(
            in: configuration, allowsGzipCaptions: allowsGzipCaptions
        ) : configuration
        try await check()
        let session = try await client.createMediaSession(clientConfiguration: offered)
        try await check()
        try await acceptMediaSession(
            session, requestActivities: requestActivities, allowsGzipCaptions: allowsGzipCaptions
        )
        return session
    }

    private func acceptMediaSession(
        _ session: MeetMediaSessionWire.Session,
        requestActivities: Bool,
        allowsGzipCaptions: Bool
    ) async throws {
        lines.append("CreateMediaSession: accepted (media credentials withheld)")
        lines.append("Native stream control setup: reading server assignment")
        let channel = try await NativeMeetStreamControl.configure(media, from: session.serverConfiguration)
        try await check()
        if requestActivities {
            let assigned = await NativeMeetStreamControl.configureActivities(
                media,
                from: session.serverConfiguration,
                allowsGzipCaptions: allowsGzipCaptions
            )
            try await check()
            assignedActivityChannels = assigned
            updateActivityAvailability()
        }
        mediaSessionName = session.name
        lines.append(channel != nil
            ? "Native stream control setup: server-assigned negotiated channel; uncompressed"
            : "Native stream control setup: legacy in-band channel")
        if let channel {
            lines
                .append("Native stream control reliability: " + NativeMeetStreamControl
                    .reliabilityLabel(channel))
        }
    }
}

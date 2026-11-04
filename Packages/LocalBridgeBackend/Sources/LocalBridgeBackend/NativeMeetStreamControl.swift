import Foundation
import GChatBridgeCore

enum NativeMeetStreamControl {
    static func configure(
        _ media: any CallMediaEngine, from configuration: Data
    ) async throws -> CallStreamControlChannel? {
        guard await media.supportsStreamControl else { return nil }
        let channel = try MeetMediaSessionWire.streamControlChannel(serverConfiguration: configuration)
        let options = channel.map {
            CallStreamControlChannel(
                id: $0.id, isOrdered: $0.ordered,
                maxPacketLifeTime: $0.maxPacketLifeTime, maxRetransmits: $0.maxRetransmits
            )
        }
        try await media.configureStreamControl(options)
        return options
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
    func acceptMediaSession(_ session: MeetMediaSessionWire.Session) async throws {
        lines.append("CreateMediaSession: accepted (media credentials withheld)")
        lines.append("Native stream control setup: reading server assignment")
        let channel = try await NativeMeetStreamControl.configure(media, from: session.serverConfiguration)
        try await check()
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
